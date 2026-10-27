import {webcrypto} from 'node:crypto';
import {afterEach, describe, expect, it, vi} from 'vitest';
import {authenticateVosViewer} from '@/utils/vosAuth';

afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    Reflect.deleteProperty(window, 'vos_platform');
});

describe('authenticateVosViewer', () => {
    it('leaves standalone and desktop-compatible builds unchanged', async () => {
        vi.stubEnv('BASE_URL', '/');
        const fetcher = vi.fn();
        vi.stubGlobal('fetch', fetcher);
        await authenticateVosViewer();
        expect(fetcher).not.toHaveBeenCalled();
    });

    it('uses PKCE and passes only the exchanged token to its own server', async () => {
        vi.stubEnv('BASE_URL', '/app/com.ictrek.pgv/');
        vi.stubGlobal('crypto', webcrypto);
        const authorize = vi.fn(async (params: Record<string, string>) => ({code: 'code', state: params.state}));
        const token = vi.fn(async () => ({access_token: 'test-access-token'}));
        Object.defineProperty(window, 'vos_platform', {configurable: true,
            value: {api: {v1000: {oauth2: {authorize, token}}}}});
        const fetcher = vi.fn<typeof fetch>().mockResolvedValue(new Response(null, {status: 204}));
        vi.stubGlobal('fetch', fetcher);
        await authenticateVosViewer();
        expect(authorize.mock.calls[0][0]).toMatchObject({client_id: 'com.ictrek.pgv', code_challenge_method: 'S256'});
        expect(fetcher).toHaveBeenCalledWith('/app/com.ictrek.pgv/api/vos/login', expect.objectContaining({
            method: 'POST', credentials: 'same-origin', body: JSON.stringify({access_token: 'test-access-token'}),
        }));
    });

    it('rejects a mismatched state before exchanging a code', async () => {
        vi.stubEnv('BASE_URL', '/app/com.ictrek.pgv/');
        vi.stubGlobal('crypto', webcrypto);
        const token = vi.fn();
        Object.defineProperty(window, 'vos_platform', {configurable: true, value: {api: {v1000: {oauth2: {
            authorize: async () => ({code: 'code', state: 'wrong-state'}), token,
        }}}}});
        await expect(authenticateVosViewer()).rejects.toThrow('VOS OIDC state mismatch');
        expect(token).not.toHaveBeenCalled();
    });
});
