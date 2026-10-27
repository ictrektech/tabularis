-- PG16 query trees and table OIDs cannot be copied into PG17. Export SQL
-- definitions using the source server, then use pg_ivm 1.15's supported
-- restore_immv API to register the existing restored tables without replacing
-- their data, OIDs, owners or dependent objects.
SET search_path = pg_catalog;
SELECT format(
  'SET ROLE %I; SELECT pgivm.restore_immv(%L, %L, false); %s RESET ROLE;',
  pg_get_userbyid(c.relowner), format('%I.%I', n.nspname, c.relname),
  pgivm.get_immv_def(m.immvrelid),
  CASE WHEN m.ispopulated THEN '' ELSE
    format('SELECT pgivm.refresh_immv(%L, false);', format('%I.%I', n.nspname, c.relname)) END
)
FROM pgivm.pg_ivm_immv m
JOIN pg_class c ON c.oid = m.immvrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
ORDER BY n.nspname, c.relname;
