import {act, cleanup, renderHook, waitFor} from '@testing-library/react';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {useVosLocale} from '@/hooks/useVosLocale';

describe('useVosLocale', () => {
    let announce: (state: {locale: string}) => void;
    const unsubscribe = vi.fn();
    const getState = vi.fn();
    beforeEach(() => {
        vi.stubEnv('BASE_URL', '/app/com.ictrek.pgv/');
        getState.mockReset().mockResolvedValue({locale: 'zh-CN'});
        Object.defineProperty(window, 'vos_platform', {
            configurable: true,
            value: {
                getState,
                broadcast: {
                    on: vi.fn((_event, handler) => {
                        announce = handler;
                        return unsubscribe;
                    }),
                },
            },
        });
    });
    afterEach(() => {
        cleanup();
        Reflect.deleteProperty(window, 'vos_platform');
        vi.unstubAllEnvs();
        vi.clearAllMocks();
    });
    it('loads the host locale and follows live changes', async () => {
        const {result, unmount} = renderHook(() => useVosLocale());
        await waitFor(() => expect(result.current).toBe('zh'));
        act(() => announce({locale: 'en-US'}));
        expect(result.current).toBe('en');
        act(() => announce({locale: 'zh_CN'}));
        expect(result.current).toBe('zh');
        unmount();
        expect(unsubscribe).toHaveBeenCalledOnce();
    });
    it('does not let a delayed snapshot overwrite a newer broadcast', async () => {
        let resolve!: (state: {locale: string}) => void;
        getState.mockReturnValue(
            new Promise((done) => {
                resolve = done;
            }),
        );
        const {result} = renderHook(() => useVosLocale());
        act(() => announce({locale: 'en-US'}));
        await act(async () => resolve({locale: 'zh-CN'}));
        expect(result.current).toBe('en');
    });
    it('keeps standalone language selection unchanged', () => {
        vi.stubEnv('BASE_URL', '/');
        const {result} = renderHook(() => useVosLocale());
        expect(result.current).toBeUndefined();
        expect(getState).not.toHaveBeenCalled();
    });
});
