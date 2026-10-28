import {useEffect} from 'react';
import {createRoot} from 'react-dom/client';
import {useTranslation} from 'react-i18next';
import i18n from 'i18next';
import {useVosLocale} from '@/hooks/useVosLocale';
import {applyThemeToCSS} from '@/themes/themeUtils';
import {tabularisLight} from '@/themes/presets/tabularisLight';
import {tabularisDark} from '@/themes/presets/tabularisDark';
import {PgvIntegrationGuide} from './PgvIntegrationGuide';

type State = {locale?: unknown; theme?: unknown};
interface GuideBridge {
    getState?: () => Promise<State>;
    broadcast?: {on: (event: 'theme-change', handler: (state: State) => void) => () => void};
}

function GuideRoot() {
    const locale = useVosLocale();
    const {i18n} = useTranslation();
    useEffect(() => {
        if (locale) void i18n.changeLanguage(locale);
    }, [i18n, locale]);
    return <PgvIntegrationGuide />;
}

/** Documentation is static: never negotiate or replace a database session. */
export async function startPgvGuide(element: HTMLElement): Promise<void> {
    const host = window as Window & {vos_platform?: GuideBridge};
    for (let attempt = 0; !host.vos_platform && attempt < 60; attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, 100));
    }
    const applyTheme = (state: State) =>
        applyThemeToCSS(state.theme === 'dark' ? tabularisDark : tabularisLight);
    applyTheme({theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'});
    let revision = 0;
    const off = host.vos_platform?.broadcast?.on('theme-change', (state) => {
        revision += 1;
        applyTheme(state);
    });
    window.addEventListener('pagehide', () => off?.(), {once: true});
    const initialRevision = revision;
    const state = await host.vos_platform?.getState?.().catch(() => undefined);
    if (state) {
        if (revision === initialRevision) applyTheme(state);
        if (typeof state.locale === 'string') {
            await i18n.changeLanguage(state.locale.toLowerCase().startsWith('zh') ? 'zh' : 'en');
        }
    }
    createRoot(element).render(<GuideRoot />);
}
