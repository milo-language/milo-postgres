#!/bin/sh
# Stand up a throwaway PostgreSQL cluster for the test suite and tear it down.
#
# It is deliberately NOT your dev server: it lives in a temp dir on port 55432
# and its pg_hba requires scram-sha-256 for TCP. A default Homebrew/apt install
# uses `trust` for localhost, under which the client's authentication path never
# runs at all — the tests would pass while SCRAM went unexercised, which is the
# one part of this client most worth proving.
#
#   sh scripts/test-server.sh start   # initdb + start, prints the DSN
#   sh scripts/test-server.sh stop    # stop + delete the data dir
set -e
DIR="${MILO_PG_DIR:-/tmp/milo-pg-test}"
PORT="${MILO_PG_PORT:-55432}"
PW="${MILO_PG_PASSWORD:-testpw}"

case "$1" in
  start)
    rm -rf "$DIR"; mkdir -p "$DIR"
    pwfile="$DIR/.pw"; printf '%s' "$PW" > "$pwfile"
    initdb -D "$DIR/data" -U postgres --auth-local=trust \
           --auth-host=scram-sha-256 --pwfile="$pwfile" >/dev/null
    rm -f "$pwfile"
    pg_ctl -D "$DIR/data" -o "-p $PORT -k $DIR" -l "$DIR/log" start >/dev/null
    # pg_ctl returns once the postmaster is up, but the first connection can still
    # race the startup packet; pg_isready is the documented readiness check.
    for _ in $(seq 30); do
      pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1 && break
      sleep 0.2
    done
    PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U postgres -qc \
      "create database milo_test;" >/dev/null
    echo "postgres://postgres:$PW@127.0.0.1:$PORT/milo_test"
    ;;
  stop)
    [ -d "$DIR/data" ] && pg_ctl -D "$DIR/data" stop >/dev/null 2>&1 || true
    rm -rf "$DIR"
    ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
