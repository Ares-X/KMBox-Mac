#!/usr/bin/env python3
"""Read-only firmware check and loopback HTTP transfer through the release CLI."""
import hashlib,json,os,selectors,signal,socket,subprocess,sys,time,urllib.request
from pathlib import Path
binary=Path(sys.argv[1]).resolve();firmware=Path(sys.argv[2]).resolve()
port=int(sys.argv[3]) if len(sys.argv)>3 else 80
restricted=not (len(sys.argv)>4 and sys.argv[4]=="unrestricted")
original=firmware.read_bytes();expected=hashlib.sha256(original).hexdigest()
interfaces=subprocess.check_output([str(binary),'interfaces'],text=True).splitlines()
other_local=next((line.split('\t')[1] for line in interfaces if line.split('\t')[0]!='lo0'),None)
assert other_local,'negative address checks require a second existing local IPv4'
check=subprocess.run([str(binary),'firmware-check',str(firmware)],capture_output=True,timeout=10,check=True)
assert expected in check.stdout.decode()
server=subprocess.Popen([str(binary),'--local','127.0.0.1']+(['--host','127.0.0.1'] if restricted else [])+['--http-port',str(port),'firmware-serve',str(firmware)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
try:
    poller=selectors.DefaultSelector();poller.register(server.stdout,selectors.EVENT_READ)
    assert poller.select(5),'server did not become ready'
    first=server.stdout.readline().decode().strip();poller.close()
    assert first.startswith('Serving http://127.0.0.1:'), (first,server.stderr.read().decode())
    url='http://127.0.0.1:'+str(port)+'/kmboxNB.cpio'
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(urllib.request.Request(url,method='HEAD'),timeout=5) as r:
        assert int(r.headers['Content-Length'])==len(original)
        assert r.read()==b''
    with opener.open(url,timeout=15) as r:
        downloaded=r.read();assert r.status==200
    assert downloaded==original
    assert firmware.read_bytes()==original
    # Even a low-port wildcard socket must reject another destination or source.
    for destination,source in [(other_local,'127.0.0.1'),('127.0.0.1',other_local)]:
        with socket.socket() as probe:
            probe.settimeout(2);probe.bind((source,0))
            received=b''
            try:
                probe.connect((destination,port))
                probe.sendall(b'GET /kmboxNB.cpio HTTP/1.0\r\n\r\n')
                while True:
                    chunk=probe.recv(65536)
                    if not chunk:break
                    received+=chunk
            except (ConnectionError,TimeoutError,socket.timeout): pass
            if not restricted and destination=='127.0.0.1':
                assert received.split(b'\r\n\r\n',1)[1]==original,'optional source filter blocked a valid local source'
            else:assert received==b'',(destination,source,received[:100])
    server.send_signal(signal.SIGINT)
    out,err=server.communicate(timeout=5)
    assert server.returncode==0,(out,err)
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        probe.setsockopt(socket.IPPROTO_IP,25,socket.if_nametoindex('lo0'))
        probe.bind(('0.0.0.0' if port<1024 else '127.0.0.1',port))
    print(json.dumps({'status':'passed','uid':os.getuid(),'source_restriction':restricted,'interface':'lo0','destination':'127.0.0.1:'+str(port),'bytes':len(downloaded),'sha256':expected,'checks':['offline CPIO check','HEAD length','HTTP GET exact file bytes','source unchanged','other destination rejected',('other source rejected' if restricted else 'other source allowed'),'SIGINT stops service','port released'],'hardware_flash':'NOT_EXERCISED'},indent=2))
finally:
    if server.poll() is None:
        server.terminate()
        try:server.wait(timeout=3)
        except subprocess.TimeoutExpired:server.kill();server.wait()
