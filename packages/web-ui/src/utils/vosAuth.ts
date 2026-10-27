import {webPath} from './webBase';

interface VosOAuth2 {
    authorize(params: Record<string, string>): Promise<{code: string; state: string}>;
    token(params: Record<string, string>): Promise<{access_token: string}>;
}

/** Exchange a fresh VOS identity before initializing any database state. */
export async function authenticateVosViewer(): Promise<void> {
    if (import.meta.env.BASE_URL !== '/app/com.ictrek.pgv/') return;
    const host = window as Window & {
        vos_platform?: {api?: {v1000?: {oauth2?: VosOAuth2}}};
    };
    let bridge: VosOAuth2 | undefined;
    for (let attempt = 0; attempt < 60; attempt += 1) {
        bridge = host.vos_platform?.api?.v1000?.oauth2;
        if (bridge) break;
        await new Promise((resolve) => setTimeout(resolve, 100));
    }
    if (!bridge) throw new Error('Open PGV from the VOS sidebar to sign in.');
    const encode = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes))
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    const random = () => encode(crypto.getRandomValues(new Uint8Array(32)));
    const verifier = random();
    const state = random();
    const challenge = encode(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
    const clientId = 'com.ictrek.pgv';
    const result = await bridge.authorize({client_id: clientId, response_type: 'code',
        scope: 'openid profile email', state, nonce: random(), code_challenge: challenge,
        code_challenge_method: 'S256'});
    if (result.state !== state) throw new Error('VOS OIDC state mismatch');
    const tokens = await bridge.token({grant_type: 'authorization_code', code: result.code,
        code_verifier: verifier, client_id: clientId});
    if (!tokens.access_token) throw new Error('VOS did not return an access token');
    const response = await fetch(webPath('/api/vos/login'), {method: 'POST',
        credentials: 'same-origin', headers: {'content-type': 'application/json'},
        body: JSON.stringify({access_token: tokens.access_token})});
    if (!response.ok) throw new Error('PGV database administration requires the VOS admin account.');
}
