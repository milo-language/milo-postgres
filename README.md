# postgres

This is a package for the [Milo language](https://milo-language.github.io/milo/).

## Overview

Talk to PostgreSQL: connect with a URL, run queries, read rows.

```milo
var db = Conn.connect("postgres://user:pw@127.0.0.1:5432/shop")!
```

It speaks wire protocol v3 directly, so there is no libpq and no C dependency
for the protocol itself. Authentication covers SCRAM-SHA-256, MD5, cleartext and
trust, and for SCRAM the server's own signature is verified rather than merely
accepted. TLS is off by default and opted into through the DSN.

Absent rather than stubbed in v0.1: connection pooling, `COPY`,
`LISTEN`/`NOTIFY`, prepared-statement caching, and the binary result format.

Full API, the type mapping, error fields and TLS behaviour:
[docs/api.md](docs/api.md).

## Installation

```bash
milo add github.com/milo-language/milo-postgres
```

```milo
from "postgres" import { Conn, PgValue }
```

## Examples

### Connecting and querying

```milo
from "postgres" import { Conn, PgValue }

fn main(): i32 {
    var db = Conn.connect("postgres://user:pw@127.0.0.1:5432/shop")!

    var params: Vec<PgValue> = Vec.new()
    params.push(PgValue.Text("ada"))
    let rows = db.queryParams("select id, name, score from people where name = $1", params)!

    for row in rows.all() {
        print($"{row.i64("id") ?? 0} {row.str("name") ?? ""} {row.f64("score") ?? 0.0}")
    }

    db.close()
    return 0
}
```

```
1 ada 99.5
```

`Conn.connect` returns once the server has answered `ReadyForQuery`, so a
successful result means the session is usable, not merely that the socket
opened. Everything in the DSN but the host is optional: the port defaults to
5432, the user to `postgres`, and an omitted database means "same name as the
user", which is libpq's rule.

### Parameters, and the injection they close

Reach for `queryParams` whenever any part of a query came from outside your
program. Parameters travel in the `Bind` message as length-prefixed values in
their own protocol fields, and the server never re-parses them as SQL:

```milo
var p: Vec<PgValue> = Vec.new()
p.push(PgValue.Text("'; drop table people --"))
let r = db.queryParams("select $1::text as echoed", p)!
print(r.str(0, "echoed") ?? "")

let still = db.query("select count(*) from people")!
print($"people still has {still.i64At(0, 0) ?? -1} rows")
```

```
'; drop table people --
people still has 3 rows
```

Concatenating that same text into `sql` and calling `query` is the hole this
closes. Placeholders are PostgreSQL's positional `$1`, `$2`, … matching the
order of `params`; add an explicit cast (`$1::uuid`) where the context is
ambiguous.

### Transactions, including the failed state

```milo
db.begin()!
db.exec("update accounts set balance = balance - 10 where id = 1")!
print($"in transaction: {db.inTransaction()}, status {db.txStatusName()}")

// A failed statement does not end the transaction, it poisons it.
match db.query("select * from nope") {
    Result.Ok(_rows) => {
    }
    Result.Err(e) => {
        print($"{e.code}: {e.message}")
    }
}
print($"failed: {db.txFailed()}, status {db.txStatusName()}")

db.rollback()!
print($"after rollback: {db.txStatusName()}")
```

```
in transaction: true, status in transaction
42P01: relation "nope" does not exist
failed: true, status failed transaction
after rollback: idle
```

The transaction status from every `ReadyForQuery` is tracked, which is what
makes that middle state visible. `TX_FAILED` rejects every further statement
with `25P02` until it is rolled back, and without tracking it that reads as a
run of unrelated errors. Note also that the error did not abandon the exchange:
the client kept reading to `ReadyForQuery`, so the connection was still usable
for the rollback.
