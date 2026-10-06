-- The exact number of rows in every table of the public schema, one line per table.
--
-- It's the same text on both sides of the restore drill's last check (docs/backups.md): script/restore-drill.sh
-- runs it against the restored copy, and the operator pastes it into `docker compose run --rm kamal dbc -d
-- <destination>` for the live database. Plain count(*), not pg_class.reltuples, which is an estimate.
SELECT table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint AS row_count
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;
