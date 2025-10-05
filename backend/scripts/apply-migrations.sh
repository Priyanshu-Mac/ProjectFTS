#!/bin/sh
set -euo pipefail

echo "[migrate] Connecting to Postgres at ${PGHOST:-localhost}:${PGPORT:-5432} db=${PGDATABASE:-} user=${PGUSER:-}"

# Wait for DB to be ready
until PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -c "select 1" >/dev/null 2>&1; do
  echo "[migrate] Waiting for database..."
  sleep 2
done

# If a single file is provided, apply it directly and exit (no schema_migrations bookkeeping)
simple_apply_and_exit() {
  FILEPATH="$1"
  if [ ! -f "$FILEPATH" ]; then
    echo "[migrate] ERROR: file not found: $FILEPATH"
    exit 1
  fi
  FILENAME="$(basename "$FILEPATH")"
  echo "[migrate] Applying single SQL file: $FILENAME"
  # Optional: reset the public schema to avoid 'already exists' errors on re-runs
  if [ "${RESET_DB:-false}" = "true" ]; then
    echo "[migrate] RESET_DB=true -> Dropping and recreating schema public"
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;"
  fi
  TMP_FILE="$(mktemp)"
  # Strip non-standard dump markers like \restrict/\unrestrict if present
  sed '/^\\restrict/d; /^\\unrestrict/d' "$FILEPATH" > "$TMP_FILE"
  # If dump tries to set ownership to a non-existent role 'postgres', rewrite to current PGUSER
  if [ "${PGUSER}" != "postgres" ]; then
    # Replace patterns like: ALTER ... OWNER TO postgres;  (also handle optional quotes)
    sed -i -E "s/OWNER TO \"?postgres\"?;/OWNER TO ${PGUSER};/g" "$TMP_FILE"
  fi
  PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -f "$TMP_FILE"
  echo "[migrate] Applied $FILENAME"
  exit 0
}

# If explicitly requested, apply only one file and exit (no tracking)
if [ -n "${APPLY_ONLY_FILE:-}" ]; then
  simple_apply_and_exit "$APPLY_ONLY_FILE"
fi

# Special-case: if a LatestDBExport.sql (or LatestDbExport.sql) is mounted, apply only that (no tracking)
if [ -f /extras/LatestDBExport.sql ]; then
  simple_apply_and_exit /extras/LatestDBExport.sql
fi
if [ -f /extras/LatestDbExport.sql ]; then
  simple_apply_and_exit /extras/LatestDbExport.sql
fi

echo "[migrate] Database is up. Ensuring schema_migrations table exists..."
PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (
  file_name text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
SQL

apply_one_and_exit() {
  FILEPATH="$1"
  if [ ! -f "$FILEPATH" ]; then
    echo "[migrate] ERROR: file not found: $FILEPATH"
    exit 1
  fi
  FILENAME="$(basename "$FILEPATH")"
  echo "[migrate] Preparing (single) $FILENAME"
  COUNT=$(PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -t -A -c "SELECT count(*) FROM schema_migrations WHERE file_name = '$FILENAME'" || echo 0)
  if [ "$COUNT" = "0" ]; then
    # Sanitize dump of any non-standard psql meta commands like \restrict/\unrestrict that some tools add
    TMP_FILE="$(mktemp)"
    # remove lines starting with \restrict or \unrestrict
    sed '/^\\restrict/d; /^\\unrestrict/d' "$FILEPATH" > "$TMP_FILE"
    echo "[migrate] Applying (single) $FILENAME"
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -f "$TMP_FILE"
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -c "INSERT INTO schema_migrations(file_name) VALUES ('$FILENAME')"
    echo "[migrate] Applied $FILENAME"
  else
    echo "[migrate] Skipping $FILENAME (already applied)"
  fi
  echo "[migrate] Single-file migration done."
  exit 0
}

# Note: the single-file fast path above exits before this point

apply_file() {
  FILEPATH="$1"
  FILENAME="$(basename "$FILEPATH")"
  echo "[migrate] Considering $FILENAME"
  COUNT=$(PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -t -A -c "SELECT count(*) FROM schema_migrations WHERE file_name = '$FILENAME'" || echo 0)
  if [ "$COUNT" = "0" ]; then
    echo "[migrate] Applying $FILENAME"
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -f "$FILEPATH"
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -c "INSERT INTO schema_migrations(file_name) VALUES ('$FILENAME')"
    echo "[migrate] Applied $FILENAME"
  else
    echo "[migrate] Skipping $FILENAME (already applied)"
  fi
}

# Apply migrations from directory in lexicographic order
if ls /migrations/*.sql >/dev/null 2>&1; then
  for f in $(ls -1 /migrations/*.sql | sort); do
    apply_file "$f"
  done
else
  echo "[migrate] No files found in /migrations"
fi

# Optionally apply extra root-level SQLs if present (once)
# Keep support for these legacy extras if present
[ -f /extras/latest.sql ] && apply_file /extras/latest.sql
[ -f /extras/sqlfilelatest2.sql ] && apply_file /extras/sqlfilelatest2.sql

echo "[migrate] All done."
