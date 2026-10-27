-- Run as the PGV superuser before applications resume. Never drop application data.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '30min';
SELECT pg_advisory_xact_lock(2295, 16);
SELECT set_config('ictrek.force_bm25_rebuild', :'force_rebuild', true);
DO $$
DECLARE
    installed TEXT;
    major INT := current_setting('server_version_num')::int / 10000;
BEGIN
    IF major NOT IN (16, 17) THEN
        RAISE EXCEPTION 'Unsupported PGV PostgreSQL major version %', major;
    END IF;
    SELECT extversion INTO installed FROM pg_extension WHERE extname = 'pg_search';
    IF installed IS NULL THEN
        RAISE EXCEPTION 'pg_search is required for HybRAG keyword search';
    END IF;
    IF major = 17 THEN
        IF installed <> '0.25.11' THEN
            RAISE EXCEPTION 'PG17 requires pg_search 0.25.11; restore into a fresh PG17 cluster rather than reusing a PG16 data directory (found %)', installed;
        END IF;
    ELSIF installed <> '0.22.6' THEN
        IF installed NOT IN ('0.22.2', '0.22.3', '0.22.4', '0.22.5') THEN
            RAISE EXCEPTION 'Unvalidated pg_search upgrade from % to 0.22.6; no downgrade attempted', installed;
        END IF;
        ALTER EXTENSION pg_search UPDATE TO '0.22.6';
    END IF;
END $$;

-- A committed marker prevents a blocking rebuild on every provision run.
-- Keep maintenance metadata outside the application's public schema.
CREATE SCHEMA IF NOT EXISTS ictrek_pgv;
CREATE TABLE IF NOT EXISTS ictrek_pgv.maintenance (
    name TEXT PRIMARY KEY,
    completed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_am a ON a.oid = c.relam
        WHERE i.indexrelid = to_regclass('public.embeddings_search_idx')
          AND i.indrelid = to_regclass('public.embeddings') AND a.amname IN ('bm25', 'paradedb')
    ) AND (
        current_setting('ictrek.force_bm25_rebuild')::boolean OR
        NOT EXISTS (SELECT 1 FROM ictrek_pgv.maintenance WHERE name =
            CASE WHEN current_setting('server_version_num')::int / 10000 = 17
                 THEN 'bm25-0.25.11' ELSE 'bm25-0.22.6' END)
    ) THEN
        REINDEX INDEX public.embeddings_search_idx;
        INSERT INTO ictrek_pgv.maintenance(name) VALUES (
            CASE WHEN current_setting('server_version_num')::int / 10000 = 17
                 THEN 'bm25-0.25.11' ELSE 'bm25-0.22.6' END)
        ON CONFLICT (name) DO UPDATE SET completed_at = now();
        RAISE NOTICE 'Rebuilt public.embeddings_search_idx for installed pg_search';
    END IF;
END $$;
COMMIT;
