/** VOS boundary: same-origin routing, verified administrator login and managed PGV connections. */
import http from 'node:http';
import {readFile, stat} from 'node:fs/promises';
import {resolve, extname} from 'node:path';
import {randomBytes} from 'node:crypto';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export const BASE = '/app/com.ictrek.pgv';
const INTERNAL = 'http://localhost:8082';
const HOP = new Set(['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailer', 'transfer-encoding', 'upgrade']);

export function sameOrigin(request) {
    const origin = request.headers.origin;
    if (!origin) return !['POST', 'PUT', 'PATCH', 'DELETE'].includes(request.method);
    try {
        const url = new URL(origin);
        return ['http:', 'https:'].includes(url.protocol) && url.host === request.headers.host;
    } catch { return false; }
}

export function scopedCookie(cookie, secure) {
    return cookie.replace(/Path=\//i, `Path=${BASE}/`) + (secure ? '; Secure' : '');
}

export function upstreamHeaders(headers) {
    const result = {};
    for (const [name, value] of Object.entries(headers)) {
        if (!HOP.has(name) && !name.startsWith('x-forwarded-') &&
            !name.startsWith('x-tabularis-proxy-') && name !== 'x-tabularis-user' && name !== 'host' && name !== 'origin') result[name] = value;
    }
    result.host = 'localhost:8082';
    if (headers.origin) result.origin = INTERNAL;
    return result;
}

function reply(response, status, body = '') {
    response.writeHead(status, {'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store'});
    response.end(body);
}

async function bodyJson(request) {
    const chunks = []; let size = 0;
    for await (const chunk of request) {
        size += chunk.length;
        if (size > 32768) throw new Error('Request too large');
        chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString());
}

export async function verifyAdministrator(token, userinfoUrl, fetcher = fetch) {
    if (typeof token !== 'string' || !token || token.length > 16384) throw new Error('Invalid token');
    const response = await fetcher(userinfoUrl, {headers: {authorization: `Bearer ${token}`},
        redirect: 'error', signal: AbortSignal.timeout(10000)});
    if (!response.ok) throw new Error('Invalid VOS session');
    const payload = await response.json();
    if (payload.code !== undefined && payload.code !== 0) throw new Error('Invalid VOS session');
    const claims = payload.data || payload;
    // This workspace contains shared database superuser credentials, not private per-user databases.
    if (typeof claims.sub !== 'string' || !claims.sub || (claims.preferred_username || claims.username) !== 'admin') {
        throw new Error('VOS administrator required');
    }
    return String(claims.sub);
}

async function newSession(secret, user) {
    const response = await fetch(`${INTERNAL}/api/v1/session`, {headers: {
        'x-tabularis-proxy-secret': secret, 'x-tabularis-user': user},
        signal: AbortSignal.timeout(10000)});
    if (!response.ok) throw new Error('Viewer session unavailable');
    return {cookie: response.headers.getSetCookie()[0], session: await response.json()};
}

async function rpc(auth, command, payload = {}) {
    const response = await fetch(`${INTERNAL}/api/v1/rpc/${command}`, {method: 'POST',
        headers: {cookie: auth.cookie.split(';')[0], origin: INTERNAL,
            'x-tabularis-csrf': auth.session.csrfToken, 'content-type': 'application/json'},
        body: JSON.stringify(payload), signal: AbortSignal.timeout(30000)});
    const result = await response.json();
    if (!response.ok || !result.ok) throw new Error(`Managed connection setup failed: ${command}`);
    return result.data;
}

export async function seedConnections(secret, env = process.env) {
    const auth = await newSession(secret, 'pgv-provisioner');
    try {
        const connections = await rpc(auth, 'get_connections');
        const specs = [
            {name: 'PGV PostgreSQL', driver: 'postgres', host: env.PGHOST || 'pgv',
                port: Number(env.PGPORT || 5432), username: env.PGUSER || 'postgres',
                password: env.PGPASSWORD, database: env.PGDATABASE || 'postgres', ssl_mode: 'disable'},
            {name: 'PGV Redis', driver: 'redis', host: env.PGV_REDIS_HOST || 'pgv-redis',
                port: 6379, username: '', password: env.PGV_REDIS_PASSWORD, database: '0'},
        ];
        for (const {name, ...params} of specs) {
            if (!params.password) throw new Error('PGV connection credentials are required');
            const existing = connections.find((connection) => connection.name === name);
            const saved = await rpc(auth, existing ? 'update_connection' : 'save_connection', {
                ...(existing ? {id: existing.id} : {}), name,
                params: {...params, save_in_keychain: true}, environment: 'production'});
            await rpc(auth, 'test_connection', {request: {connection_id: saved.id, params: saved.params}});
        }
    } finally {
        await fetch(`${INTERNAL}/api/v1/logout`, {method: 'POST', headers: {
            cookie: auth.cookie.split(';')[0], origin: INTERNAL,
            'x-tabularis-csrf': auth.session.csrfToken}}).catch(() => {});
    }
}

export function createGateway({secret, userinfoUrl, webRoot = '/usr/lib/tabularis/web-ui'}) {
    const identities = new Map();
    const identityCookie = (headers) => (headers.cookie || '').split(';')
        .map((part) => part.trim().split('='))
        .find(([name]) => name === 'pgv_vos_session')?.[1];
    const invalidate = (id) => {
        const identity = identities.get(id);
        if (identity) for (const socket of identity.sockets) socket.destroy();
        identities.delete(id);
    };
    const requireIdentity = async (request) => {
        const id = identityCookie(request.headers);
        const identity = identities.get(id);
        if (!identity || identity.expires < Date.now()) {invalidate(id); throw new Error('VOS session required');}
        try {await verifyAdministrator(identity.token, userinfoUrl);}
        catch {invalidate(id); throw new Error('VOS session expired');}
        return identity;
    };
    const server = http.createServer(async (request, response) => {
        try {
            const pathname = new URL(request.url, 'http://localhost').pathname;
            if (pathname === '/') {response.writeHead(307, {location: `${BASE}/`}); return response.end();}
            if (pathname === '/healthz') return reply(response, 200, 'OK');
            if (!pathname.startsWith(`${BASE}/`)) return reply(response, 404);
            if (!sameOrigin(request)) return reply(response, 403);
            const path = request.url.slice(BASE.length);
            if (pathname === `${BASE}/api/vos/login`) {
                if (request.method !== 'POST') return reply(response, 405);
                invalidate(identityCookie(request.headers));
                response.setHeader('set-cookie', [
                    `pgv_vos_session=; Path=${BASE}/; HttpOnly; SameSite=Strict; Max-Age=0`,
                    `tabularis_session=; Path=${BASE}/; HttpOnly; SameSite=Strict; Max-Age=0`,
                ]);
                // Revoke the previous backend session when switching VOS users or refreshing.
                try {
                    const previous = await fetch(`${INTERNAL}/api/v1/session`, {
                        headers: {cookie: request.headers.cookie || ''}});
                    if (previous.ok) {
                        const prior = await previous.json();
                        await fetch(`${INTERNAL}/api/v1/logout`, {method: 'POST', headers: {
                            cookie: request.headers.cookie || '', origin: INTERNAL,
                            'x-tabularis-csrf': prior.csrfToken}});
                    }
                } catch {}
                try {
                    const {access_token: token} = await bodyJson(request);
                    const user = await verifyAdministrator(token, userinfoUrl);
                    // Replace any previous user's backend session on every document bootstrap.
                    const auth = await newSession(secret, user);
                    // Reuse the native session restore flow to open both managed connections.
                    const connections = await rpc(auth, 'get_connections');
                    const managed = ['PGV PostgreSQL', 'PGV Redis'].map((name) =>
                        connections.find((connection) => connection.name === name)?.id).filter(Boolean);
                    await rpc(auth, 'set_last_open_connections', {connectionIds: managed});
                    await rpc(auth, 'set_last_active_connection', {connectionId: managed[0] || null});
                    for (const [id, identity] of identities) if (identity.expires < Date.now()) invalidate(id);
                    if (identities.size >= 500) throw new Error('Session limit reached');
                    const id = randomBytes(32).toString('hex');
                    identities.set(id, {token, expires: Date.now() + 12 * 60 * 60 * 1000, sockets: new Set()});
                    const secure = request.headers['x-forwarded-proto'] === 'https';
                    response.setHeader('set-cookie', [scopedCookie(auth.cookie, secure),
                        `pgv_vos_session=${id}; Path=${BASE}/; HttpOnly; SameSite=Strict; Max-Age=43200${secure ? '; Secure' : ''}`]);
                    return reply(response, 204);
                } catch { return reply(response, 403, 'VOS administrator required'); }
            }
            if (path.startsWith('/api/')) {
                try {await requireIdentity(request);} catch {return reply(response, 401);}
                if (path === '/api/v1/logout') invalidate(identityCookie(request.headers));
                const proxy = http.request(`${INTERNAL}${path}`, {method: request.method,
                    headers: upstreamHeaders(request.headers)}, (upstream) => {
                    const headers = Object.fromEntries(Object.entries(upstream.headers).filter(([key]) => !HOP.has(key)));
                    if (headers['set-cookie']) headers['set-cookie'] = headers['set-cookie'].map((cookie) =>
                        scopedCookie(cookie, request.headers['x-forwarded-proto'] === 'https'));
                    // Plugin sandbox headers remain strict; only the app shell permits same-origin frames.
                    response.writeHead(upstream.statusCode, headers);
                    upstream.pipe(response);
                });
                proxy.on('error', () => reply(response, 502));
                request.on('aborted', () => proxy.destroy());
                request.pipe(proxy); return;
            }
            if (request.method !== 'GET' && request.method !== 'HEAD') return reply(response, 405);
            const root = resolve(webRoot);
            let file = resolve(root, `.${decodeURIComponent(pathname.slice(BASE.length))}`);
            if (!file.startsWith(`${root}/`) && file !== root) return reply(response, 404);
            try { if (!(await stat(file)).isFile()) file = resolve(root, 'index.html'); }
            catch { file = resolve(root, 'index.html'); }
            const types = {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
                '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2', '.json': 'application/json'};
            const body = await readFile(file);
            response.writeHead(200, {'content-type': types[extname(file)] || 'application/octet-stream',
                'content-security-policy': "base-uri 'self'; object-src 'none'; frame-ancestors 'self'",
                'x-content-type-options': 'nosniff', 'cache-control': 'no-cache'});
            response.end(request.method === 'HEAD' ? undefined : body);
        } catch { if (!response.headersSent) reply(response, 500); else response.destroy(); }
    });
    server.on('upgrade', async (request, socket, head) => {
        if (request.url?.split('?')[0] !== `${BASE}/api/v1/events` || !sameOrigin(request)) return socket.destroy();
        let identity;
        try {identity = await requireIdentity(request);} catch {return socket.destroy();}
        identity.sockets.add(socket);
        socket.on('close', () => identity.sockets.delete(socket));
        const headers = upstreamHeaders(request.headers);
        headers.connection = 'Upgrade'; headers.upgrade = 'websocket';
        const proxy = http.request(`${INTERNAL}${request.url.slice(BASE.length)}`, {headers});
        proxy.on('upgrade', (response, upstream, upstreamHead) => {
            socket.write(`HTTP/1.1 101 Switching Protocols\r\n${Object.entries(response.headers)
                .map(([key, value]) => `${key}: ${value}`).join('\r\n')}\r\n\r\n`);
            if (head.length) upstream.write(head);
            if (upstreamHead.length) socket.write(upstreamHead);
            socket.pipe(upstream); upstream.pipe(socket);
            socket.on('error', () => upstream.destroy()); upstream.on('error', () => socket.destroy());
            socket.on('close', () => upstream.destroy()); upstream.on('close', () => socket.destroy());
        });
        proxy.on('response', (response) => {response.resume(); socket.destroy();});
        proxy.on('error', () => socket.destroy()); proxy.end();
    });
    return server;
}

async function main() {
    const secret = randomBytes(48).toString('hex');
    const child = spawn('/usr/bin/tabularis', ['web', '--no-open', '--host', '127.0.0.1',
        '--port', '8082', '--auth', 'proxy', '--allow-high-risk', '--public-url', INTERNAL, '--allowed-origin', INTERNAL],
    {stdio: 'inherit', env: {...process.env, TABULARIS_WEB_PROXY_SECRET: secret}});
    child.on('exit', (code) => process.exit(code || 0));
    const stop = () => child.kill('SIGTERM');
    process.on('SIGTERM', stop); process.on('SIGINT', stop);
    for (let attempt = 0; ; attempt += 1) {
        try { const response = await fetch(`${INTERNAL}/healthz`); if (response.ok) break; } catch {}
        if (attempt === 60) throw new Error('Viewer backend did not become ready');
        await new Promise((resolve) => setTimeout(resolve, 500));
    }
    await seedConnections(secret);
    const server = createGateway({secret, userinfoUrl: process.env.VOS_USERINFO_URL});
    server.listen(8081, '0.0.0.0', () => console.log('PGV viewer ready'));
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    main().catch((error) => {console.error('PGV viewer startup failed:', error instanceof Error ? error.message : 'Unknown error'); process.exit(1);});
}
