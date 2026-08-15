#!/bin/sh
# The whole gate in one command: bring up a throwaway PostgreSQL, run the test
# suite and the example against it, cross-check the writes with psql, and tear the
# server down whether or not any of that passed.
#
#   sh scripts/run-tests.sh
#   MILO="bun run ../../milo/src/main.ts" sh scripts/run-tests.sh   # from a checkout
set -e
cd "$(dirname "$0")/.."
MILO="${MILO:-milo}"
PORT="${MILO_PG_PORT:-55432}"
PW="${MILO_PG_PASSWORD:-testpw}"

# EXIT alone is not enough: a ^C during the test run leaves a postmaster and a
# data dir behind, and the next run's initdb then fails on a non-empty directory.
cleanup() {
  sh scripts/test-server.sh stop >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "==> starting throwaway server"
MILO_PG_DSN="$(sh scripts/test-server.sh start)"
export MILO_PG_DSN
echo "    $MILO_PG_DSN"

echo "==> tests"
$MILO test tests/postgres_test.milo

# Separate file, separate reason: these need the certificate the harness makes,
# which CI's PostgreSQL service container has no equivalent of. They are not
# optional here — a TLS test that skips itself proves nothing.
echo "==> tls tests"
$MILO test tests/tls_test.milo

echo "==> example"
$MILO run examples/query.milo

# The suite up to here is this client agreeing with itself. psql is a second,
# independent implementation reading the same rows — without this step a client
# that mis-encoded every parameter identically on write and read would look fine.
echo "==> psql cross-check"
q() {
  PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U postgres -d milo_test -tAc "$1"
}
rows=$(q "select count(*) from milo_example")
[ "$rows" = "4" ] || { echo "psql sees $rows rows in milo_example, expected 4"; exit 1; }
# The row the example inserted through a bind parameter is still one string of
# data. If it had been interpolated, the table would not be here to count.
evil=$(q "select name from milo_example where id = 2")
[ "$evil" = "'); drop table milo_example; --" ] || { echo "bind parameter did not round-trip: [$evil]"; exit 1; }
nulls=$(q "select count(*) from milo_example where score is null")
[ "$nulls" = "1" ] || { echo "expected exactly one NULL score, psql sees $nulls"; exit 1; }
echo "    psql agrees: 4 rows, the injection payload stored as data, 1 NULL score"

echo "==> all green"
