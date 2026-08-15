#!/bin/sh
# Stand up a throwaway PostgreSQL cluster for the test suite and tear it down.
#
# It is deliberately NOT your dev server: it lives in a temp dir on port 55432
# and its pg_hba requires scram-sha-256 for TCP. A default Homebrew/apt install
# uses `trust` for localhost, under which the client's authentication path never
# runs at all — the tests would pass while SCRAM went unexercised, which is the
# one part of this client most worth proving.
#
# Two extra roles exist for the same reason, one per remaining auth method, each
# pinned to its own pg_hba line ahead of the catch-all:
#   md5user / md5pw       -> `md5`      (password stored md5-encrypted)
#   plainuser / plainpw   -> `password` (cleartext over the wire)
# Without them the md5 and cleartext code paths are dead code that nothing runs.
#
#   sh scripts/test-server.sh start   # initdb + start, prints the DSN
#   sh scripts/test-server.sh stop    # stop + delete the data dir
set -e
DIR="${MILO_PG_DIR:-/tmp/milo-pg-test}"
PORT="${MILO_PG_PORT:-55432}"
PW="${MILO_PG_PASSWORD:-testpw}"

case "$1" in
  start)
    # Stop any previous cluster FIRST. Deleting the data dir out from under a live
    # postmaster leaves it running and holding the port, and the new server then
    # fails to bind with only "could not start server" to go on.
    [ -d "$DIR/data" ] && pg_ctl -D "$DIR/data" stop >/dev/null 2>&1 || true
    rm -rf "$DIR"; mkdir -p "$DIR"
    pwfile="$DIR/.pw"; printf '%s' "$PW" > "$pwfile"
    initdb -D "$DIR/data" -U postgres --auth-local=trust \
           --auth-host=scram-sha-256 --pwfile="$pwfile" >/dev/null
    rm -f "$pwfile"
    # pg_hba is first-match-wins, so the per-role lines have to precede the
    # scram catch-all initdb wrote or they would never be reached.
    hba="$DIR/data/pg_hba.conf"
    { printf 'host all md5user 127.0.0.1/32 md5\nhost all plainuser 127.0.0.1/32 password\n'
      cat "$hba"; } > "$hba.new"
    mv "$hba.new" "$hba"
    # TLS. Self-signed, so the certificate is also its own CA and `sslrootcert=`
    # can point straight at it. The SANs cover both spellings of localhost because
    # the client always verifies the hostname (std/fetch has no way to turn that
    # off), so a cert without them would be rejected however it was reached.
    openssl req -new -x509 -days 2 -nodes -text \
      -subj "/CN=localhost" \
      -addext "subjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1" \
      -out "$DIR/data/server.crt" -keyout "$DIR/data/server.key" >/dev/null 2>&1
    chmod 600 "$DIR/data/server.key"
    cp "$DIR/data/server.crt" "$DIR/server.crt"
    { echo "ssl = on"
      echo "ssl_cert_file = 'server.crt'"
      echo "ssl_key_file = 'server.key'"; } >> "$DIR/data/postgresql.conf"
    pg_ctl -D "$DIR/data" -o "-p $PORT -k $DIR" -l "$DIR/log" start >/dev/null
    # pg_ctl returns once the postmaster is up, but the first connection can still
    # race the startup packet; pg_isready is the documented readiness check.
    for _ in $(seq 30); do
      pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1 && break
      sleep 0.2
    done
    PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U postgres -qc \
      "create database milo_test;" >/dev/null
    # password_encryption decides how the verifier is STORED, which is what the
    # `md5` auth method needs; `password` auth works against either form.
    PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U postgres -d milo_test -q >/dev/null <<'SQL'
set password_encryption = 'md5';
create user md5user password 'md5pw';
set password_encryption = 'scram-sha-256';
create user plainuser password 'plainpw';
SQL
    echo "postgres://postgres:$PW@127.0.0.1:$PORT/milo_test"
    ;;
  stop)
    [ -d "$DIR/data" ] && pg_ctl -D "$DIR/data" stop >/dev/null 2>&1 || true
    rm -rf "$DIR"
    ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
