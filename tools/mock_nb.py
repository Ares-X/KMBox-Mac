#!/usr/bin/env python3
"""Local test fixture, not NB firmware. No third-party packages.

UDP is restricted to loopback. The PTY executes Python in a child process whose
working directory is a temporary test folder. Run only trusted test scripts:
this emulates a REPL, not a security sandbox or MicroPython compatibility.
"""
import argparse
import binascii
import io
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import traceback


def worker(root):
    os.chdir(root)
    sys.modules['ubinascii'] = binascii
    sys.modules['uos'] = os
    original_out = sys.stdout

    def event(value):
        original_out.write(json.dumps(value, ensure_ascii=True) + '\n')
        original_out.flush()

    class Output:
        def write(self, value):
            if value:
                event({'stdout': value})
            return len(value)

        def flush(self):
            pass

    context = {'__name__': '__main__'}
    for line in sys.stdin:
        code = json.loads(line)['code']
        errors = io.StringIO()
        sys.stdout, sys.stderr = Output(), errors
        try:
            exec(compile(code, '<mock-raw-repl>', 'exec'), context)
        except BaseException:
            traceback.print_exc(file=errors)
        finally:
            sys.stdout, sys.stderr = original_out, sys.__stderr__
        event({'end': errors.getvalue()})


def serve(info_path, root, log_path):
    root.mkdir(parents=True, exist_ok=True)
    demo = root / 'hello.py'
    if not demo.exists():
        demo.write_text("print('Hello from mock NB — 模拟设备')\n", encoding='utf-8')
    master, slave = os.openpty()
    os.set_blocking(master, False)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(('127.0.0.1', 0))
    child = subprocess.Popen([sys.executable, '-u', __file__, '--worker', str(root)],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             start_new_session=True)
    os.set_blocking(child.stdout.fileno(), False)
    selector = selectors.DefaultSelector()
    selector.register(master, selectors.EVENT_READ, 'serial')
    selector.register(udp, selectors.EVENT_READ, 'udp')
    selector.register(child.stdout, selectors.EVENT_READ, 'worker')
    info = {'host': '127.0.0.1', 'port': udp.getsockname()[1], 'uuid': '12345678',
            'serial': os.ttyname(slave), 'root': str(root), 'pid': os.getpid()}
    info_path.parent.mkdir(parents=True, exist_ok=True)
    info_path.write_text(json.dumps(info, indent=2), encoding='utf-8')
    print(json.dumps(info), flush=True)
    code = bytearray()
    worker_buffer = bytearray()
    raw = running = interrupted = False
    stopping = False
    peripheral = bytes.fromhex("34127856bc9af0de0203")
    monitor_peer = None
    next_report = 0.0

    def stop(*_):
        nonlocal stopping
        stopping = True

    def write_serial(data):
        # The test messages are bounded; handle partial nonblocking PTY writes.
        while data and not stopping:
            try:
                count = os.write(master, data)
                data = data[count:]
            except BlockingIOError:
                import select
                select.select([], [master], [], 0.1)

    def log(value):
        if log_path:
            with log_path.open('a', encoding='utf-8') as handle:
                handle.write(json.dumps(value, ensure_ascii=False) + '\n')

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopping:
            if monitor_peer and time.monotonic() >= next_report:
                udp.sendto(bytes.fromhex('0101fdff070000000202041a0000000000000000'), monitor_peer)
                next_report = time.monotonic() + 0.05
            for key, _ in selector.select(0.02):
                if key.data == 'udp':
                    data, peer = udp.recvfrom(4096)
                    if len(data) < 16:
                        continue
                    uuid, random, sequence, command = struct.unpack('<IIII', data[:16])
                    log({'transport': 'udp', 'sequence': sequence, 'command': hex(command),
                         'parameter': random, 'bytes': len(data), 'payload': data[16:].hex()})
                    reply = data[:16]
                    if command == 0xadce1238:
                        if random == 1 and len(data) == 26: peripheral = data[16:]
                        reply += peripheral
                    if command == 0x27388020:
                        monitor_peer = (peer[0], random & 0xffff) if random else None
                        if monitor_peer: udp.sendto(bytes.fromhex('000102'), monitor_peer)
                    udp.sendto(reply, peer)
                elif key.data == 'serial':
                    try:
                        data = os.read(master, 65536)
                    except BlockingIOError:
                        continue
                    for byte in data:
                        if byte == 3:
                            if running and not interrupted:
                                interrupted = True
                                os.kill(child.pid, signal.SIGINT)
                            elif not running:
                                code.clear()
                        elif byte == 1 and not running:
                            raw = True
                            code.clear()
                            write_serial(b'raw REPL; CTRL-B to exit\r\n>')
                        elif byte == 2 and not running:
                            raw = False
                            code.clear()
                            write_serial(b'\r\n>>> ')
                        elif byte == 4 and raw and not running:
                            source = code.decode('utf-8')
                            code.clear()
                            log({'transport': 'serial', 'code': source})
                            running, interrupted = True, False
                            write_serial(b'OK')
                            child.stdin.write((json.dumps({'code': source}) + '\n').encode())
                            child.stdin.flush()
                        elif running and byte not in (1, 2, 3, 4):
                            child.stdin.write(b'\n' if byte == 13 else bytes([byte]))
                            child.stdin.flush()
                        elif raw and not running:
                            code.append(byte)
                elif key.data == 'worker':
                    output = os.read(child.stdout.fileno(), 65536)
                    if not output:
                        raise RuntimeError('Mock interpreter exited unexpectedly')
                    worker_buffer.extend(output)
                    while b'\n' in worker_buffer:
                        line, _, remaining = worker_buffer.partition(b'\n')
                        worker_buffer = bytearray(remaining)
                        event = json.loads(line)
                        if 'stdout' in event:
                            write_serial(event['stdout'].encode('utf-8'))
                        if 'end' in event:
                            write_serial(b'\x04' + event['end'].encode('utf-8') + b'\x04>')
                            running = False
    finally:
        selector.close()
        child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        udp.close()
        os.close(master)
        os.close(slave)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker')
    parser.add_argument('--info', type=Path)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--log', type=Path)
    args = parser.parse_args()
    if args.worker:
        worker(args.worker)
    else:
        if not args.info:
            parser.error('--info is required')
        if args.root:
            serve(args.info.resolve(), args.root.resolve(), args.log)
        else:
            with tempfile.TemporaryDirectory(prefix='kmbox-mock-') as temp:
                serve(args.info.resolve(), Path(temp), args.log)
