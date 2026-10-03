#!/usr/bin/env bash
# Usage: DATABASE_URL=postgres://... ./run_tests.sh   (use a throwaway database)
set -euo pipefail
for f in sql/01_schema.sql sql/02_close_and_reopen.sql sql/03_period_guard.sql tests/test_ledger.sql; do
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$f"
done
