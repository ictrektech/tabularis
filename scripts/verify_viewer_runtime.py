#!/usr/bin/env python3
"""Disposable native viewer acceptance; never joins vos_default or uses installed data."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--image', required=True)
parser.add_argument('--postgres-image', required=True)
parser.add_argument('--redis-image', required=True)
parser.add_argument('--keep-for-ui', action='store_true')
args = parser.parse_args()
project = 'tabularis-check-' + secrets.token_hex(4)
root = Path(tempfile.mkdtemp(prefix=project + '-', dir=Path.home()/'dev/build'))
os.chmod(root, 0o700)
password = secrets.token_urlsafe(24)
base = '/app/com.ictrek.pgv'


def docker(*command, **kwargs):
    result = subprocess.run(['docker', *command], text=True, capture_output=True, **kwargs)
    if result.returncode:
        (root/'docker-error.log').write_text(result.stderr)
        os.chmod(root/'docker-error.log', 0o600)
        raise RuntimeError('Docker acceptance command failed: ' + command[0])
    return result.stdout.strip()


def client(url, payload=None, cookie=None, origin=None, headers=None):
    request_headers = dict(headers or {})
    if cookie: request_headers['Cookie'] = cookie
    if origin: request_headers['Origin'] = origin
    if payload is not None: request_headers['Content-Type'] = 'application/json'
    req = Request(url, data=None if payload is None else json.dumps(payload).encode(), headers=request_headers)
    with urlopen(req, timeout=30) as response:
        return response.status, response.headers, response.read()


def ready(url):
    for _ in range(120):
        try:
            if client(url)[0] == 200: return
        except (OSError, HTTPError): pass
        cid = docker(*cmd, 'ps', '-aq', 'viewer')
        if cid and docker('inspect', '--format', '{{.State.Status}}', cid) == 'exited':
            raise RuntimeError('Candidate viewer exited during startup')
        time.sleep(1)
    raise RuntimeError('Candidate did not become healthy')


mock = """import http from 'node:http';
http.createServer((req,res)=>{
 const admin=req.headers.authorization==='Bearer validation-admin';
 const ordinary=req.headers.authorization==='Bearer validation-user';
 res.writeHead(admin||ordinary?200:401,{'content-type':'application/json'});
 res.end(JSON.stringify({code:0,data:{sub:admin?'admin-subject':'user-subject',preferred_username:admin?'admin':'user'}}));
}).listen(8090,'0.0.0.0');"""
(root/'userinfo.mjs').write_text(mock)
compose = {
    'services': {
        'postgres': {'image': args.postgres_image, 'environment': {
            'POSTGRES_PASSWORD': password, 'POSTGRES_USER': 'postgres', 'POSTGRES_DB': 'postgres'},
            'networks': {'default': {'aliases': ['pgv']}},
            'healthcheck': {'test': ['CMD-SHELL', 'pg_isready -h 127.0.0.1 -U postgres'], 'interval': '2s', 'retries': 30}},
        'redis': {'image': args.redis_image, 'command': ['redis-server', '--requirepass', password],
                  'networks': {'default': {'aliases': ['pgv-redis']}}},
        'userinfo': {'image': args.image, 'entrypoint': ['node', '/userinfo.mjs'],
                     'volumes': [str(root/'userinfo.mjs')+':/userinfo.mjs:ro'],
                     'healthcheck': {'disable': True}},
        'viewer': {'image': args.image, 'environment': {'PGHOST': 'pgv', 'PGUSER': 'postgres',
                    'PGPASSWORD': password, 'PGV_REDIS_PASSWORD': password,
                    'VOS_USERINFO_URL': 'http://userinfo:8090/userinfo'},
                   'ports': ['127.0.0.1::8081'], 'volumes': ['viewer-data:/data'],
                   'depends_on': {'postgres': {'condition': 'service_healthy'}}},
    }, 'volumes': {'viewer-data': {}},
}
# userinfo's read-only test script must be readable by a process in the container.
os.chmod(root, 0o755)
config = root/'compose.json'
config.write_text(json.dumps(compose)); os.chmod(config, 0o600)
cmd = ['compose', '-p', project, '-f', str(config)]
succeeded = False
try:
    docker(*cmd, 'up', '-d')
    address = docker(*cmd, 'port', 'viewer', '8081')
    origin = 'http://' + address
    ready(origin+'/healthz')
    status, headers, page = client(origin+base+'/')
    assert status == 200 and b'/app/com.ictrek.pgv/assets/' in page
    assert "frame-ancestors 'self'" in headers['Content-Security-Policy']
    try: client(origin+base+'/api/v1/session')
    except HTTPError as error: assert error.code == 401
    else: raise AssertionError('Unauthenticated API accepted')
    for token in ['invalid', 'validation-user']:
        try: client(origin+base+'/api/vos/login', {'access_token': token}, origin=origin)
        except HTTPError as error: assert error.code == 403
        else: raise AssertionError('Unprivileged VOS identity accepted')
    _, headers, _ = client(origin+base+'/api/vos/login', {'access_token': 'validation-admin'}, origin=origin)
    cookie = '; '.join(item.split(';')[0] for item in headers.get_all('Set-Cookie'))
    assert f'Path={base}/' in headers['Set-Cookie']
    _, _, body = client(origin+base+'/api/v1/session', cookie=cookie)
    session = json.loads(body)
    # A failed account switch revokes both the VOS gateway and native sessions.
    try: client(origin+base+'/api/vos/login', {'access_token': 'validation-user'}, cookie=cookie, origin=origin)
    except HTTPError as error: assert error.code == 403
    try: client(origin+base+'/api/v1/session', cookie=cookie)
    except HTTPError as error: assert error.code == 401
    else: raise AssertionError('Previous administrator session survived an account switch')
    _, headers, _ = client(origin+base+'/api/vos/login', {'access_token': 'validation-admin'}, origin=origin)
    cookie = '; '.join(item.split(';')[0] for item in headers.get_all('Set-Cookie'))
    _, _, body = client(origin+base+'/api/v1/session', cookie=cookie); session = json.loads(body)

    def rpc(command, payload=None):
        _, _, body = client(origin+base+'/api/v1/rpc/'+command, payload or {}, cookie=cookie,
                            origin=origin, headers={'x-tabularis-csrf': session['csrfToken']})
        data = json.loads(body)
        assert data['ok'], 'RPC failed: ' + command
        return data['data']

    connections = rpc('get_connections')
    managed = {c['name']: c for c in connections}
    assert {'PGV PostgreSQL', 'PGV Redis'} <= set(managed)
    assert rpc('get_last_open_connections') == [managed['PGV PostgreSQL']['id'], managed['PGV Redis']['id']]
    for connection in managed.values():
        assert connection['params'].get('password') in [None, '']
        assert rpc('test_connection', {'request': {'connection_id': connection['id'],
                   'params': connection['params']}}) is not False
    # Writes use the same native command as the editor and saved server-side credentials.
    # Persisted connection JSON must not contain either injected password.
    docker(*cmd, 'exec', '-T', 'viewer', 'node', '-e',
           "const fs=require('fs'); const text=fs.readFileSync('/data/connections.json','utf8');"
           "if(text.includes(process.env.PGPASSWORD)||text.includes(process.env.PGV_REDIS_PASSWORD)) process.exit(1);")
    pgid = managed['PGV PostgreSQL']['id']
    result = rpc('execute_query', {'connectionId': pgid, 'query': 'SELECT 42 AS answer'})
    assert '42' in json.dumps(result)
    rpc('execute_query', {'connectionId': pgid, 'query': 'CREATE EXTENSION IF NOT EXISTS vector'})
    vector = rpc('execute_query', {'connectionId': pgid, 'query': "SELECT '[1,2,3]'::vector AS embedding"})
    assert '1,2,3' in json.dumps(vector).replace(' ', '')
    redisid = managed['PGV Redis']['id']
    rpc('execute_query', {'connectionId': redisid, "query": "INSERT INTO keys (key, value) VALUES ('pgv-check:viewer', 'preserved')"})
    assert 'preserved' in json.dumps(rpc('execute_query', {'connectionId': redisid, "query": "SELECT * FROM keys WHERE key = 'pgv-check:viewer'"}))
    # Confirm native CSRF checks are still active behind the VOS gateway.
    try: client(origin+base+'/api/v1/rpc/get_connections', {}, cookie=cookie, origin=origin)
    except HTTPError as error: assert error.code == 403
    else: raise AssertionError('Missing CSRF token accepted')
    # Exercise the actual WebSocket handshake, cookie and origin boundaries.
    host, port = address.rsplit(':', 1)
    with socket.create_connection((host, int(port)), timeout=10) as ws:
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        ws.sendall((f'GET {base}/api/v1/events HTTP/1.1\r\nHost: {address}\r\nOrigin: {origin}\r\n'
                    f'Cookie: {cookie}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n'
                    f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        assert b'101 Switching Protocols' in ws.recv(8192)
    ids = {name: connection['id'] for name, connection in managed.items()}
    docker(*cmd, 'up', '-d', '--force-recreate', 'viewer')
    address = docker(*cmd, 'port', 'viewer', '8081'); origin = 'http://'+address
    ready(origin+'/healthz')
    _, headers, _ = client(origin+base+'/api/vos/login', {'access_token': 'validation-admin'}, origin=origin)
    cookie = '; '.join(item.split(';')[0] for item in headers.get_all('Set-Cookie'))
    _, _, body = client(origin+base+'/api/v1/session', cookie=cookie); session = json.loads(body)
    assert {c['name']: c['id'] for c in rpc('get_connections')} == ids
    assert '42' in json.dumps(rpc('execute_query', {'connectionId': pgid, 'query': 'SELECT 42 AS answer'}))
    succeeded = True
    print('PASS: iframe/path, verified admin login, auth/CSRF rejection, automatic PG/Redis connections, native queries, WebSocket and persisted IDs/secrets')
except Exception:
    # Logs may contain third-party connection diagnostics: retain privately, do not print.
    (root/'viewer.log').write_text(docker(*cmd, 'logs', '--no-color'))
    os.chmod(root/'viewer.log', 0o600)
    print(f'Candidate diagnostics retained at {root}/viewer.log')
    raise
finally:
    if succeeded and args.keep_for_ui:
        print(f'UI_ORIGIN={origin} UI_PROJECT={project} UI_CONFIG={config}')
    else:
        docker(*cmd, 'down', '-v')
        # Successful runs leave no credentials or test data behind.
        if not (root/'viewer.log').exists(): shutil.rmtree(root)
