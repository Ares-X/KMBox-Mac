#!/usr/bin/env python3
"""Exercise the compiled CLI through real loopback UDP and a PTY test device."""
import json
import os
from pathlib import Path
import signal
import struct
import socket
import subprocess
import sys
import tempfile
import time

package = Path(__file__).resolve().parent.parent
binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else package / '.build/debug/kmctl'
with tempfile.TemporaryDirectory(prefix='kmbox-cli-') as folder:
    folder = Path(folder)
    info = folder / 'device.json'
    log = folder / 'device-events.jsonl'
    server = subprocess.Popen([sys.executable, str(package / 'tools/mock_nb.py'), '--info', str(info),
                               '--root', str(folder / 'board'), '--log', str(log)], stdout=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 5
        while not info.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        device = json.loads(info.read_text())
        serial = [str(binary), '--serial', device['serial']]
        net = [str(binary), '--host', device['host'], '--port', str(device['port']), '--uuid', device['uuid']]
        checks = []

        def run(prefix, *args, status=0):
            result = subprocess.run(prefix + list(args), capture_output=True, timeout=15)
            assert result.returncode == status, (args, result.returncode, result.stderr.decode(errors='replace'))
            checks.append(' '.join(args))
            return result

        # Invalid local input must be rejected before any handshake or serial interruption.
        def events():
            return log.read_bytes() if log.exists() else b''

        # Exercise the real kernel EPIPE path in an isolated child. The GUI and CLI
        # share NetClient; an unusable UDP socket must report failure, not SIGPIPE.
        fault_library = folder / 'net-send-epipe.dylib'
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-o', str(fault_library),
                        str(package / 'tools/fixtures/net-send-epipe.c')], check=True, capture_output=True, timeout=30)
        fault_environment = os.environ.copy()
        fault_environment['DYLD_INSERT_LIBRARIES'] = str(fault_library)
        before_fault = events()
        failed_send = subprocess.run(net + ['connect'], env=fault_environment,
                                     capture_output=True, timeout=10, restore_signals=True)
        assert failed_send.returncode == 1, (failed_send.returncode, failed_send.stderr)
        assert b'Broken pipe' in failed_send.stderr, failed_send.stderr
        assert events() == before_fault, 'A failed send must not reach the device'
        checks.append('UDP EPIPE reports failure instead of terminating from SIGPIPE')

        invalid_serial = [('unknown',), ('cat',), ('ls', '/', 'extra'), ('mv', 'old'),
                          ('run', str(folder / 'missing.py')), ('put', str(folder / 'missing.bin'), '/x'),
                          ('exec', "print('bad')\x03"), ('--baud', '12345', 'ls')]
        invalid_net = [('auto-move', '1', '2', '0'), ('auto-move', '1', '2', '10001'),
                       ('bezier-move', '1', '2', '500', '0', '0', '40000', '0'),
                       ('bezier-move', '1', '2', '500'), ('--monitor-output', str(folder / 'unused.jsonl'), 'connect'),
                       ('--stats', 'ping'), ('unknown',), ('move', '40000', '0'), ('key', '1'), ('scroll', '999'),
                       ('info', 'extra'), ('set-network', 'bad', '8888'), ('set-network', '192.168.2.188', '0'),
                       ('set-vidpid', 'fffff', '1'), ('curve', 'bezier', '101'), ('curve', 'unknown', '50'),
                       ('mode', 'unknown'), ('parsing', '255', '255'), ('parsing', '33', '1'),
                       ('monitor', 'nan'), ('monitor', '1', '80'), ('hold', '1', '.5'), ('hold', '4', 'inf'),
                       ('reboot', 'extra'), ('click', 'left', 'extra'), ('connect', 'extra'), ('--timeout', 'oops', 'connect'),
                       ('ping', 'extra'), ('chip-id', 'extra')]
        for prefix, cases in [(serial, invalid_serial), (net, invalid_net)]:
            for arguments in cases:
                before = events()
                run(prefix, *arguments, status=1)
                assert events() == before, ('invalid command touched device', arguments)

        before = events()
        result = json.loads(run([str(binary), '--host', '127.0.0.1', '--local', '127.0.0.1'], 'ping').stdout)
        assert result['reached'] and result['milliseconds'] is not None
        assert events() == before, 'ICMP ping must not create a Net session'
        for arguments in [('connect',), ('move', '-3', '7'), ('click', 'right'), ('key', '4'), ('scroll', '-1'), ('release',)]:
            run(net, *arguments)
        for cmd, values, wire_command in [
            ('auto-move', ['-30', '70', '500'], '0xaede7346'),
            ('bezier-move', ['-30', '70', '500', '-10', '20', '30', '-40'], '0xa238455a')]:
            before = len(events().splitlines())
            result = run(net, cmd, *values, '--stats')
            stats = json.loads(result.stderr.splitlines()[-1])['netStatistics']
            assert stats['sent'] == stats['acknowledged'] == 2 and stats['timeouts'] == 0
            packets = [json.loads(line) for line in events().splitlines()[before:]]
            assert len(packets) == 2 and packets[1]['command'] == wire_command and packets[1]['parameter'] == 500
            payload = struct.unpack('<14i', bytes.fromhex(packets[1]['payload']))
            assert payload[:4] == (0, -30, 70, 0)
            assert payload[4:8] == ((-10, 20, 30, -40) if cmd == 'bezier-move' else (0, 0, 0, 0))
            assert not any(payload[8:])
        result = json.loads(run(net, 'info').stdout)
        assert result['vendorID'] == 0x1234 and result['mouseMode'] == 2
        for arguments in [('set-network', '192.168.2.188', '8888'), ('set-vidpid', '1234', 'abcd'),
                          ('curve', 'rt-arm', '73'), ('curve', 'off'), ('mode', 'bypass'), ('mode', 'km'), ('reboot',)]:
            run(net, *arguments)
        curve_events = [json.loads(line) for line in events().splitlines() if json.loads(line).get('command') == '0xbbcdddac']
        assert [event['parameter'] for event in curve_events] == [0x03000049, 0]
        result = json.loads(run(net, 'parsing', '32', '255').stdout)
        assert result['mouseMode'] == 32 and result['keyboardMode'] == 255 and result['vendorID'] == 0x1234

        def monitor_port():
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                for port in range(20000, 49000):
                    try: sock.bind(('127.0.0.1', port)); return str(port)
                    except OSError: continue
            raise AssertionError('No monitor test port available')

        result = json.loads(run(net, 'monitor', '.2', monitor_port()).stdout)
        assert result['accepted'] > 0 and result['latest']['x'] == -3
        assert result['received'] == result['accepted'] + result['undecodable']
        assert result['foreignSource'] == 0 and result['extended'] == 0
        export = folder / 'monitor.jsonl'
        result = json.loads(run(net, 'monitor', '.2', monitor_port(), '--monitor-output', str(export), '--stats').stdout)
        rows = [json.loads(line) for line in export.read_bytes().splitlines()]
        assert rows[0]['mode'] == 'live-stream'
        reports = rows[1:]
        assert len(reports) == result['accepted'] + result['rejected'] and len(reports) > 0
        assert len(reports) == result['received']
        assert sum('frame' not in row for row in reports) == result['undecodable']
        assert result['lastReceivedLength'] == reports[-1]['rawLength']
        assert all(row['kind'] == 'datagram' and row['sourceIPv4'] == '127.0.0.1' for row in reports)
        assert all(row['rawLength'] == len(bytes.fromhex(row['rawHex'])) for row in reports)
        assert all(row['receivedAtUnixSeconds'] > 0 and row['monotonicNanoseconds'] > 0 for row in reports)
        assert [row['sequence'] for row in reports] == list(range(1, len(reports) + 1))
        assert any(row['rawHex'] == '000102' and 'frame' not in row for row in reports)
        before_events, original = events(), export.read_bytes()
        run(net, 'monitor', '.2', monitor_port(), '--monitor-output', str(export), status=1)
        assert events() == before_events and export.read_bytes() == original
        run(net, 'monitor', '.2', monitor_port(), '--monitor-output', str(folder / 'missing' / 'log.jsonl'), status=1)
        assert events() == before_events
        before = len(events().splitlines())
        run(net, 'hold', '26', '.05')
        held = [json.loads(line) for line in events().splitlines()[before:]]
        assert held[-1]['command'] == '0x123c2c2f' and held[-1]['payload'] == '00' * 12

        for operation, target_command in [(['monitor', '30', monitor_port(), '--monitor-output', str(folder / 'interrupted.jsonl')], '0x27388020'), (['hold', '26', '10'], '0x123c2c2f')]:
            before = len(events().splitlines())
            process = subprocess.Popen(net + operation, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    entries = [json.loads(line) for line in events().splitlines()[before:]]
                    if any(entry.get('command') == target_command for entry in entries): break
                    time.sleep(.01)
                else: raise AssertionError('operation did not start')
                process.send_signal(signal.SIGINT)
                out, err = process.communicate(timeout=3)
                assert process.returncode == 130, (out, err)
                last = json.loads(events().splitlines()[-1])
                assert last['command'] == target_command
                assert last['parameter'] == 0 if operation[0] == 'monitor' else last['payload'] == '00' * 12
                if operation[0] == 'monitor':
                    rows = [json.loads(line) for line in (folder / 'interrupted.jsonl').read_bytes().splitlines()]
                    assert rows[0]['mode'] == 'live-stream', 'Interrupted recording must leave a valid log'
                checks.append('SIGINT cleans up ' + operation[0])
            finally:
                if process.poll() is None: process.kill(); process.wait()

        source = folder / 'source.bin'
        source.write_bytes(bytes(range(256)) * 5)
        remote = device['root'] + '/roundtrip.bin'
        run(serial, 'put', str(source), remote)
        run(serial, 'put', str(source), remote, status=1)
        result = run(serial, 'cat', remote)
        assert result.stdout == source.read_bytes(), 'cat must not mix connection banners with binary data'
        downloaded = folder / 'downloaded.bin'
        run(serial, 'get', remote, str(downloaded))
        assert downloaded.read_bytes() == source.read_bytes()
        run(serial, 'get', remote, str(downloaded), status=1)
        run(serial, 'get', remote, str(downloaded), '--replace')
        source.write_bytes(b'updated\x00bytes')
        run(serial, 'put', str(source), remote, '--replace')
        assert Path(remote).read_bytes() == source.read_bytes()
        assert len(list(Path(device['root']).glob('roundtrip.bin.kmbak-*'))) == 1
        run(serial, 'exec', "raise ValueError('expected failure')", status=1)
        run(serial, 'exec', "print('reused after error')")
        bom_script = folder / 'utf8-bom.py'
        bom_script.write_bytes(b'\xef\xbb\xbf' + "print('BOM 中文')\n".encode('utf-8'))
        assert run(serial, 'run', str(bom_script)).stdout.strip() == 'BOM 中文'.encode('utf-8')
        run(serial, 'mkdir', device['root'] + '/folder')
        run(serial, 'mv', remote, device['root'] + '/folder/moved.bin')
        run(serial, 'rm', device['root'] + '/folder/moved.bin')
        run(serial, 'rmdir', device['root'] + '/folder')

        running = subprocess.Popen(serial + ['exec', "import time\nwhile True:\n print('tick', flush=True)\n time.sleep(.1)"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert running.stdout.readline().strip() == b'tick'
        running.send_signal(signal.SIGINT)
        output, error = running.communicate(timeout=8)
        assert running.returncode != 0, ('Interrupted execution reported success', output, error)
        checks.append('SIGINT stops running script with nonzero exit')
        run(serial, 'exec', "print('reused after SIGINT')")
        run(serial, '--baud', '57600', 'exec', "print('custom baud')")
        run(serial, 'exec', "import os,time\n_saved_stat=os.stat\ndef _slow_stat(p):\n if str(p).endswith('/hello.py'):time.sleep(2)\n return _saved_stat(p)\nos.stat=_slow_stat")
        slow = subprocess.Popen(serial + ['cat', device['root'] + '/hello.py'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if b"print(os.stat(" in events().splitlines()[-1]: break
                time.sleep(.01)
            else: raise AssertionError('slow transfer never started')
            time.sleep(.03)
            started = time.monotonic();slow.send_signal(signal.SIGINT)
            out,err = slow.communicate(timeout=2)
            assert slow.returncode == 130, (out,err)
            assert time.monotonic()-started < 1.5, 'cancellation did not interrupt the pending transfer'
            checks.append('SIGINT cancels pending file transfer before the device delay ends')
        finally:
            if slow.poll() is None:slow.kill();slow.wait()
        run(serial, 'exec', "os.stat=_saved_stat\nprint('reused after cancelled transfer')")
        print(json.dumps({'status': 'passed', 'checks': checks}, ensure_ascii=False, indent=2))
    finally:
        server.terminate()
        try:
            server.wait(timeout=4)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
