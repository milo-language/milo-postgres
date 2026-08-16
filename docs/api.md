# postgres API

## Connecting

The DSN is a URL:

```
postgres://user:password@host:port/database?sslmode=require&application_name=svc
```

Everything but the host is optional. The port defaults to 5432, the user to
`postgres`, and an omitted database means "same name as the user" (libpq's rule).
User and password are percent-decoded, so a password containing `@` or `/` is
written `%40` / `%2F`. `postgresql://` works too.

Recognised query parameters are `sslmode`, `sslrootcert` and `application_name`;
anything else is ignored, because a DSN is usually shared with other tools.

`Conn.connect` returns once the server has answered `ReadyForQuery`, so a
successful result means the session is usable — not merely that the socket opened.

### Authentication

SCRAM-SHA-256, MD5, cleartext and trust. The client nonce is drawn from the OS
entropy source per connection, and the server's `ServerSignature` is **verified** —
that is the half of SCRAM that proves the server also knew the stored key, i.e.
that you are not talking to an impostor who simply answers "ok".

An authentication method the client does not implement (GSSAPI, SSPI, Kerberos,
SCRAM-SHA-256-PLUS) fails with a message naming it. It never falls through to
something weaker and never succeeds quietly.

## Queries

```milo
db.query(sql)                    // Result<Rows, PgError>  — simple query protocol
db.queryParams(sql, params)      // Result<Rows, PgError>  — extended, real bind parameters
db.exec(sql)                     // Result<i64, PgError>   — rows affected
db.execParams(sql, params)       // Result<i64, PgError>
```

**`queryParams` is the one to reach for when any part of the query came from
outside your program.** Parameters travel in the `Bind` message as
length-prefixed values in their own protocol fields; the server never re-parses
them as SQL. Concatenating the same text into `sql` and calling `query` is the
injection hole this closes:

```milo
var p: Vec<PgValue> = Vec.new()
p.push(PgValue.Text("'; drop table people --"))
let r = db.queryParams("select $1::text as echoed", p)!
r.str(0, "echoed")     // the literal string. The table is still there.
```

Placeholders are PostgreSQL's positional `$1`, `$2`, … matching the order of
`params`. Parameter types are left unspecified, so the server infers each one from
where it is used; add an explicit cast (`$1::uuid`) when the context is ambiguous.

A simple query may contain several statements. `Rows` then holds the **last**
result set — the shapes differ, so concatenating them would produce a table with
no consistent meaning — while `rows.commandTags()` lists every statement's
`CommandComplete` tag in order and `rows.affectedRows()` sums them.

## Reading results

`Rows` stores the header once and the cells row-major in one flat `Vec`. Index it
directly, or detach a `Row` when the values need to outlive the result set.

```milo
rows.len()                  // rows
rows.width()                // columns
rows.columns()              // Vec<string>
rows.oidAt(c)               // i32 — the column's pg_type OID
rows.commandTags()          // Vec<string>
rows.affectedRows()         // i64

rows.str(r, "name")         rows.strAt(r, c)      // Option<string>
rows.i64(r, "id")           rows.i64At(r, c)      // Option<i64>
rows.f64(r, "score")        rows.f64At(r, c)      // Option<f64>
rows.bool(r, "active")      rows.boolAt(r, c)     // Option<bool>
rows.bytes(r, "blob")       rows.bytesAt(r, c)    // Option<string> — raw bytes
rows.value(r, "x")          rows.valueAt(r, c)    // PgValue
rows.isNull(r, "x")         rows.isNullAt(r, c)   // bool

rows.at(r)                  // Row  — owned copy, same accessors minus the row index
rows.all()                  // Vec<Row>, for `for row in rows.all()`
```

**NULL is not the empty string.** A NULL column answers `None` and `isNull` is
true; an empty one answers `Some("")` and `isNull` is false. That distinction
survives every layer, including bind parameters, where `PgValue.Null` is sent as a
-1 length rather than as text.

### Types

Results arrive in the protocol's **text format** and are decoded per column OID:

| OID(s) | PostgreSQL type | Decoded as |
|---|---|---|
| 21, 23, 20, 26 | `int2` `int4` `int8` `oid` | `PgValue.Int(i64)` |
| 700, 701 | `float4` `float8` | `PgValue.Float(f64)` |
| 16 | `bool` | `PgValue.Bool(bool)` |
| 17 | `bytea` | `PgValue.Bytes(string)` — raw bytes, `\x…` and escape formats both un-escaped |
| 25, 1043, 19, 1042, 18 | `text` `varchar` `name` `bpchar` `char` | `PgValue.Text(string)` |
| 1700 | `numeric` | `PgValue.Text` — **exact decimal text** |
| 1082, 1114, 1184, 1083 | `date` `timestamp` `timestamptz` `time` | `PgValue.Text` — the server's ISO rendering |
| 2950 | `uuid` | `PgValue.Text` — canonical 8-4-4-4-12 |
| 114, 3802 | `json` `jsonb` | `PgValue.Text` — hand to `std/json` if you want a tree |

The ones that stay `Text` do so on purpose. `numeric` is arbitrary precision, and
an `f64` would silently round it — the decimal string *is* the exact value.
Temporal types keep the server's own rendering because Milo's `std/datetime`
models instants, not PostgreSQL's four distinct temporal types, and a lossy
conversion is worse than text that round-trips on input. `json` is not parsed
eagerly because that would be a cost you did not ask for.

Any other OID also arrives as `PgValue.Text` carrying the server's text, so an
unknown type degrades to something usable rather than to an error.

## Errors

Every failure — server-side or client-side — is a `PgError` with the
`ErrorResponse` decoded into fields:

```milo
match db.query("select * from nope") {
    Result.Ok(rows) => { ... }
    Result.Err(e) => {
        e.code        // "42P01"   — SQLSTATE. Branch on this.
        e.severity    // "ERROR"
        e.message     // "relation \"nope\" does not exist"
        e.detail      e.hint      e.position
        e.schema      e.table     e.column    e.constraint   e.routine
        e.toString()
    }
}
```

Branch on `code`, never on `message`: the SQLSTATE is stable across server
versions and locales, and the message is neither. Client-side failures use the
connection classes — `08000` (could not connect / connection closed / closed
connection reused) and `08P01` (protocol violation).

An `ErrorResponse` does not abandon the exchange: the client keeps reading to
`ReadyForQuery` before returning the error, so the connection stays usable and the
next query is not answered with the previous one's leftovers.

`NoticeResponse` is collected rather than printed — `db.notices()` returns them
decoded the same way, `db.clearNotices()` empties the list. `ParameterStatus` is
recorded; read it with `db.parameter("server_version")`.

## Transactions

```milo
db.begin()!
let n = db.exec("update accounts set balance = balance - 10 where id = 1")!
db.commit()!      // or db.rollback()!
```

The transaction status from every `ReadyForQuery` is tracked, which is what makes
the third state visible:

```milo
db.txStatus()        // TX_IDLE | TX_ACTIVE | TX_FAILED
db.inTransaction()   db.txFailed()   db.txStatusName()
```

`TX_FAILED` is a transaction that hit an error and now rejects every statement
with `25P02` until it is rolled back. Without tracking it, that reads as a run of
unrelated errors.

## TLS

Off by default. Opt in through the DSN:

```
postgres://user:pw@db.example.com/app?sslmode=require
postgres://user:pw@db.internal/app?sslmode=require&sslrootcert=/etc/ssl/internal-ca.pem
```

The client sends `SSLRequest` and upgrades the socket in place. `disable` (the
default), `allow`, `prefer`, `require`, `verify-ca` and `verify-full` are accepted;
`prefer` and `allow` fall back to plaintext when TLS cannot be established, the
rest fail.

**One deliberate difference from libpq:** libpq's `require` encrypts *without*
verifying the certificate. This client cannot do that — Milo's `TlsStream` always
verifies against the system trust store — so `require` here behaves like libpq's
`verify-full`. That is the safer direction to differ in, and `sslrootcert=` is how
you trust a private CA, which is the usual reason people reach for unverified TLS.

## Not implemented

Deliberately out of scope for v0.1. None of these are stubs that silently do
nothing — they are absent:

- **Connection pooling.** One `Conn` is one socket carrying one conversation.
- **`COPY`.** A `CopyInResponse` is answered with `CopyFail` and surfaces as an
  error, so a `COPY` never wedges the connection — but the data path is not there.
- **`LISTEN` / `NOTIFY`.** `NotificationResponse` is drained so it cannot break the
  reader; there is no way to receive one.
- **Prepared-statement caching.** `queryParams` uses the unnamed statement and
  re-parses every call. Correct, not optimal.
- **Binary result format.** Everything is text format. Binary would save a parse
  on ints, floats and timestamps; it is an optimisation, not a fix.
- **IPv6 literals in a DSN** (`postgres://[::1]/db`) are rejected with a message
  saying so.
- **Channel binding** (`SCRAM-SHA-256-PLUS`), GSSAPI, SSPI, Kerberos. A server
  offering only these fails with the method named.
- **Cancellation.** `BackendKeyData` is captured (`db.backendProcessId()`) but
  there is no `CancelRequest`.

## Tests

The suite needs a real server, and specifically one that does **not** trust
localhost — under `trust` the whole authentication path never executes and the
tests would be green while proving nothing about it. `scripts/test-server.sh`
builds a throwaway PostgreSQL 16 in a temp dir on port 55432 that requires
`scram-sha-256`, adds one role per remaining auth method, and turns on TLS with a
self-signed certificate.

```bash
sh scripts/run-tests.sh        # the whole gate: server up, suites, example, psql cross-check, server down
```

or by hand:

```bash
sh scripts/test-server.sh start
milo test tests/postgres_test.milo
milo test tests/tls_test.milo
milo run examples/query.milo
sh scripts/test-server.sh stop
```

The last step of `run-tests.sh` reads the example's rows back with `psql` — a
second, independent implementation — because a client that mis-encoded on write
and read agrees with itself perfectly.
