import {describe, expect, it} from 'vitest';
import {webPath} from '@/utils/webBase';

describe('webPath', () => {
    it('preserves root installs and prefixes mounted routes exactly once', () => {
        expect(webPath('/api/v1/session', '/')).toBe('/api/v1/session');
        expect(webPath('/api/v1/session', '/app/com.ictrek.pgv/')).toBe('/app/com.ictrek.pgv/api/v1/session');
        expect(webPath('/app/com.ictrek.pgv/editor', '/app/com.ictrek.pgv/')).toBe('/app/com.ictrek.pgv/editor');
        expect(webPath('https://example.com', '/app/com.ictrek.pgv/')).toBe('https://example.com');
    });
});
