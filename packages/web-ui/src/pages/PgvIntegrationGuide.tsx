import {useRef, useState, type ReactNode} from 'react';
import {useTranslation} from 'react-i18next';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import {BookOpen, Copy, Database} from 'lucide-react';
import guideZh from '../content/pgv-guide.zh.md?raw';
import guideEn from '../content/pgv-guide.en.md?raw';
import manualZh from '../../../../ictrek.app/src/README.zh-CN.md?raw';
import manualEn from '../../../../ictrek.app/src/README.en.md?raw';
import imageNotes from '../../../../pgv/README.md?raw';
import migration from '../../../../pgv/PG17-MIGRATION.md?raw';
import deployment from '../../../../VOS.md?raw';
import config from '../../../../ictrek.app/src/configs.yml?raw';

function CodeBlock({children, zh}: {children?: ReactNode; zh: boolean}) {
    const ref = useRef<HTMLPreElement>(null);
    const [status, setStatus] = useState('');
    return (
        <div className="relative my-4">
            <button
                className="absolute right-2 top-2 flex items-center gap-1 rounded border border-default bg-elevated px-2 py-1 text-xs text-secondary hover:text-accent"
                aria-label={zh ? '复制代码' : 'Copy code'}
                onClick={() => {
                    void navigator.clipboard.writeText(ref.current?.innerText ?? '').then(
                        () => setStatus(zh ? '已复制' : 'Copied'),
                        () => setStatus(zh ? '复制失败' : 'Copy failed'),
                    );
                }}
            >
                <Copy size={12} />
                {status || (zh ? '复制' : 'Copy')}
            </button>
            <pre
                ref={ref}
                className="overflow-x-auto rounded-lg border border-default bg-surface-secondary p-4 pt-10 text-xs leading-6 text-primary"
            >
                {children}
            </pre>
        </div>
    );
}

export function PgvIntegrationGuide() {
    const {i18n} = useTranslation();
    const zh = (i18n.resolvedLanguage ?? i18n.language).startsWith('zh');
    const [selected, setSelected] = useState('guide');
    const pageRef = useRef<HTMLDivElement>(null);
    const selectDocument = (id: string) => {
        setSelected(id);
        pageRef.current?.scrollTo({top: 0});
    };
    const documents = [
        {
            id: 'guide',
            title: zh ? '接入与建库' : 'Connect & create databases',
            content: zh ? guideZh : guideEn,
            source: `packages/web-ui/src/content/pgv-guide.${zh ? 'zh' : 'en'}.md`,
        },
        {
            id: 'manual',
            title: zh ? '完整用户说明' : 'Complete user manual',
            content: zh ? manualZh : manualEn,
            source: `ictrek.app/src/README.${zh ? 'zh-CN' : 'en'}.md`,
        },
        {
            id: 'images',
            title: zh ? '镜像构建与发布' : 'Images & releases',
            content: imageNotes,
            source: 'pgv/README.md',
        },
        {
            id: 'migration',
            title: zh ? 'PG16 → PG17 与恢复' : 'PG16 → PG17 & recovery',
            content: migration,
            source: 'pgv/PG17-MIGRATION.md',
        },
        {
            id: 'deployment',
            title: zh ? 'VOS 部署与验证' : 'VOS deployment & verification',
            content: deployment,
            source: 'VOS.md',
        },
        {
            id: 'config',
            title: zh ? '完整安装配置参考' : 'All installation settings',
            content:
                '# ' +
                (zh ? '完整安装配置参考' : 'All installation settings') +
                '\n\n```yaml\n' +
                config +
                '\n```',
            source: 'ictrek.app/src/configs.yml',
        },
    ];
    const current = documents.find((doc) => doc.id === selected) ?? documents[0];
    const repo = 'https://github.com/ictrektech/tabularis/blob/main/';
    return (
        <div ref={pageRef} className="h-screen overflow-y-auto bg-base text-primary">
            <header className="border-b border-default bg-elevated px-5 py-4 sm:px-8">
                <div className="mx-auto flex max-w-6xl items-center gap-3">
                    <img
                        src={`${import.meta.env.BASE_URL}pgv-logo.svg`}
                        alt="V-PGV"
                        className="h-12 w-12"
                    />
                    <div className="flex-1">
                        <h1 className="text-xl font-semibold">
                            PGV · {zh ? '接入指南' : 'Integration Guide'}
                        </h1>
                        <p className="mt-1 text-sm text-secondary">PostgreSQL 17 · Redis · VOS</p>
                    </div>
                    <a
                        href="/#/app/com.ictrek.pgv/pgv"
                        target="_top"
                        className="flex items-center gap-2 rounded-lg border border-default px-3 py-2 text-sm text-accent hover:bg-surface-secondary"
                    >
                        <Database size={16} />
                        {zh ? '数据库连接器' : 'Database Connector'}
                    </a>
                </div>
            </header>
            <div className="mx-auto grid max-w-6xl gap-8 p-5 sm:p-8 md:grid-cols-[220px_minmax(0,1fr)]">
                <nav
                    aria-label={zh ? '指南文档' : 'Guide documents'}
                    className="self-start md:sticky md:top-6"
                >
                    <div className="mb-3 flex items-center gap-2 text-sm font-semibold">
                        <BookOpen size={16} />
                        {zh ? '文档库' : 'Document library'}
                    </div>
                    <div className="flex flex-col gap-1">
                        {documents.map((doc) => (
                            <button
                                key={doc.id}
                                aria-current={doc.id === current.id ? 'page' : undefined}
                                className={`rounded-lg px-3 py-2.5 text-left text-sm ${doc.id === current.id ? 'bg-accent-primary/10 font-semibold text-accent' : 'text-secondary hover:bg-surface-secondary'}`}
                                onClick={() => selectDocument(doc.id)}
                            >
                                {doc.title}
                            </button>
                        ))}
                    </div>
                    <p className="mt-5 text-xs leading-5 text-muted">
                        {zh
                            ? '完整原文随版本离线提供。账户表列出初始值；已覆盖的配置以当前安装为准。'
                            : 'Full source documents are bundled offline. Account tables show initial defaults; installation overrides take precedence.'}
                    </p>
                </nav>
                <main className="min-w-0 rounded-xl border border-default bg-elevated p-5 sm:p-8">
                    <div className="mb-6 flex flex-wrap items-center justify-between gap-2 border-b border-default pb-4 text-xs text-muted">
                        <span>{current.title}</span>
                        <a
                            href={repo + current.source}
                            target="_blank"
                            rel="noreferrer"
                            className="text-accent hover:underline"
                        >
                            {zh ? '查看源码文档' : 'Source document'} ↗
                        </a>
                    </div>
                    <article className="text-sm leading-7 text-secondary [&_h1]:mb-6 [&_h1]:text-2xl [&_h1]:font-semibold [&_h1]:text-primary [&_h2]:mb-4 [&_h2]:mt-10 [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:text-primary [&_h3]:mb-3 [&_h3]:mt-7 [&_h3]:font-semibold [&_h3]:text-primary [&_p]:my-3 [&_ul]:my-3 [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:my-3 [&_ol]:list-decimal [&_ol]:pl-5 [&_li]:my-1 [&_a]:text-accent [&_a]:underline [&_strong]:text-primary [&_code]:font-mono [&_code]:text-xs [&_blockquote]:border-l-2 [&_blockquote]:border-focus [&_blockquote]:pl-4">
                        <Markdown
                            remarkPlugins={[remarkGfm]}
                            components={{
                                pre: ({children}) => <CodeBlock zh={zh}>{children}</CodeBlock>,
                                table: ({children}) => (
                                    <div className="my-5 overflow-x-auto">
                                        <table className="w-full border-collapse text-left text-xs [&_th]:border [&_th]:border-default [&_th]:bg-surface-secondary [&_th]:p-3 [&_th]:font-semibold [&_td]:border [&_td]:border-default [&_td]:p-3">
                                            {children}
                                        </table>
                                    </div>
                                ),
                                a: ({href, children}) => {
                                    const doc = href?.endsWith('PG17-MIGRATION.md')
                                        ? 'migration'
                                        : href?.endsWith('VOS.md')
                                          ? 'deployment'
                                          : href === 'README.md'
                                            ? 'images'
                                            : undefined;
                                    if (doc)
                                        return (
                                            <button
                                                className="text-accent underline"
                                                onClick={() => selectDocument(doc)}
                                            >
                                                {children}
                                            </button>
                                        );
                                    const url =
                                        href?.startsWith('http') || href?.startsWith('#')
                                            ? href
                                            : new URL(href ?? '', repo + current.source).href;
                                    return (
                                        <a href={url} target="_blank" rel="noreferrer">
                                            {children}
                                        </a>
                                    );
                                },
                            }}
                        >
                            {current.content}
                        </Markdown>
                    </article>
                </main>
            </div>
        </div>
    );
}
