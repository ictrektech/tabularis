import {useEffect, useState} from 'react';

type Locale = 'zh' | 'en';
interface VosLocaleBridge {
    getState?: () => Promise<{locale?: unknown}>;
    broadcast?: {
        on: (event: 'locale-change', handler: (state: {locale?: unknown}) => void) => () => void;
    };
}

/** VOS injects its bridge before authentication completes and the UI mounts. */
export function useVosLocale(): Locale | undefined {
    const [locale, setLocale] = useState<Locale>();
    useEffect(() => {
        if (import.meta.env.BASE_URL !== '/app/com.ictrek.pgv/') return;
        const bridge = (window as Window & {vos_platform?: VosLocaleBridge}).vos_platform;
        let active = true;
        let revision = 0;
        const apply = (state: {locale?: unknown}) => {
            if (!active || typeof state.locale !== 'string') return;
            setLocale(state.locale.toLowerCase().startsWith('zh') ? 'zh' : 'en');
        };
        const off = bridge?.broadcast?.on('locale-change', (state) => {
            revision += 1;
            apply(state);
        });
        const snapshotRevision = revision;
        void bridge
            ?.getState?.()
            .then((state) => {
                if (snapshotRevision === revision) apply(state);
            })
            .catch(() => undefined);
        return () => {
            active = false;
            off?.();
        };
    }, []);
    return locale;
}
