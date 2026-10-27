import {test} from 'node:test';
import assert from 'node:assert/strict';
import {sameOrigin, scopedCookie, upstreamHeaders, verifyAdministrator, BASE} from './gateway.mjs';

test('mutations and WebSockets reject foreign origins and missing mutation origins', () => {
    assert.equal(sameOrigin({method: 'POST', headers: {host: 'vos.example'}}), false);
    assert.equal(sameOrigin({method: 'POST', headers: {host: 'vos.example', origin: 'https://evil.example'}}), false);
    assert.equal(sameOrigin({method: 'POST', headers: {host: 'vos.example:1180', origin: 'https://vos.example:1180'}}), true);
});
test('untrusted proxy identity headers cannot create backend sessions', () => {
    const headers = upstreamHeaders({'x-tabularis-proxy-secret': 'attacker',
        'x-tabularis-user': 'admin', 'x-forwarded-for': '127.0.0.1',
        origin: 'https://vos.example', host: 'vos.example', cookie: 'session=value'});
    assert.equal(headers['x-tabularis-proxy-secret'], undefined);
    assert.equal(headers['x-tabularis-user'], undefined);
    assert.equal(headers['x-forwarded-for'], undefined);
    assert.equal(headers.origin, 'http://localhost:8082');
    assert.equal(headers.cookie, 'session=value');
});
test('viewer cookies are scoped to its mount path', () => {
    assert.equal(scopedCookie('tabularis_session=opaque; Path=/; HttpOnly', true),
        `tabularis_session=opaque; Path=${BASE}/; HttpOnly; Secure`);
});
test('only a server-verified VOS admin can obtain a shared database session', async () => {
    const success = (claims) => async () => ({ok: true, json: async () => claims});
    assert.equal(await verifyAdministrator('token', 'http://userinfo', success({code: 0,
        data: {sub: 'subject', preferred_username: 'admin'}})), 'subject');
    await assert.rejects(verifyAdministrator('token', 'http://userinfo', success({sub: 'subject', preferred_username: 'user'})));
    await assert.rejects(verifyAdministrator('token', 'http://userinfo', success({code: 1, data: {sub: 'x', preferred_username: 'admin'}})));
    await assert.rejects(verifyAdministrator('token', 'http://userinfo', async () => ({ok: false})));
});

test('an old native cookie or forged proxy identity cannot bypass the VOS gateway', async () => {
    const {createGateway} = await import('./gateway.mjs');
    const server = createGateway({secret: 'server-only', userinfoUrl: 'http://invalid.invalid'});
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    try {
        const response = await fetch(`http://127.0.0.1:${server.address().port}${BASE}/api/v1/session`, {
            headers: {cookie: 'tabularis_session=old-session',
                'x-tabularis-proxy-secret': 'forged', 'x-tabularis-user': 'admin'},
        });
        assert.equal(response.status, 401);
    } finally {
        server.closeAllConnections();
        await new Promise((resolve) => server.close(resolve));
    }
});
