# Wire protocol notes

Findings from probing a real PostgreSQL 16 server before writing the client, so
the implementation does not have to rediscover them.

## Milo strings carry binary fine

`string` is an owned UTF-8 byte buffer, but nothing rejects non-UTF-8 content or
**embedded NULs** — which matters, because the startup packet is a NUL-delimited
key/value list and result rows are arbitrary bytes. A probe sent a startup packet
with four NUL terminators and read back a 24-byte binary reply with no escaping
or corruption. So `TcpStream.send(&string)` / `recvOnce() -> string` are a usable
byte channel; there is no need for a separate `Vec<u8>` path.

## Framing

`Bytes.writeI32Be` / `Bytes.readI32Be` from `std/binary` match the protocol's
big-endian length prefixes exactly. Verified: a startup packet whose declared
length was `body.len + 4` was accepted, and the server's reply framed as
`1 byte tag | i32 length | payload`.

## The startup parameter list needs a final NUL

`user\0postgres\0database\0milo_test\0` is **not** enough — the list itself is
terminated by one more NUL. Omit it and the server answers `ErrorResponse` ('E',
tag 69) rather than an authentication request, with no hint that the terminator
is what is missing. This cost a debugging cycle; it is the single easiest thing
to get wrong in the handshake.

## The test server really does require SCRAM

Against `scripts/test-server.sh`, the first server message is tag `'R'` (82) with
auth code **10** = `AuthenticationSASL`, i.e. SCRAM-SHA-256. A stock Homebrew or
apt install uses `trust` for localhost and answers code 0 (`AuthenticationOk`)
immediately — under which the entire authentication path never runs and the
tests prove nothing about it. That is why the harness builds its own cluster.

## SCRAM-SHA-256 is proven, not assumed

`docs/scram-probe.milo` completes the full exchange against a real PostgreSQL 16
in safe Milo and reaches `AuthenticationOk`. Run it with the harness up:

    sh scripts/test-server.sh start
    milo run docs/scram-probe.milo

Every primitive comes from std and they compose byte-exactly:

    SaltedPassword  = Pbkdf2.sha256(password, salt, i, 32)
    ClientKey       = Hmac.sha256Bytes(SaltedPassword, "Client Key")
    StoredKey       = Sha256.bytes(ClientKey)
    AuthMessage     = client-first-bare + "," + server-first + "," + client-final-without-proof
    ClientSignature = Hmac.sha256Bytes(StoredKey, AuthMessage)
    ClientProof     = ClientKey XOR ClientSignature

Two things the probe hard-codes that a real client must not:

* **The nonce is fixed** (`milofixednonce123456`) so the exchange is reproducible
  while debugging. A client MUST draw it from `std/random` per connection — a
  predictable client nonce defeats the point of the challenge.
* **The password is inline.** It belongs in the connection config, and the
  `SaltedPassword` derivation is the expensive step (4096 PBKDF2 rounds by
  default), so a pool should cache it per (password, salt, iterations).

The server's final message carries `v=<ServerSignature>`, which a correct client
**verifies** — it is what proves the server also knew the stored key, i.e. that
you are not talking to an impostor. The probe does not check it; the client must.

## What building the client added to this list

* **The probe's two fakes and its one omission are all closed.** `lib.milo` draws
  the nonce from `std/random` per connection, takes the password from the DSN, and
  verifies the server's `v=` ServerSignature. That last check is live, not
  decorative: comparing it against the *client* signature instead makes
  `testConnectOverScram` fail with "server signature mismatch", which is how it
  was confirmed to be load-bearing.
* **An `ErrorResponse` is not the end of the exchange.** The server still owes a
  `ReadyForQuery`, and returning the error without reading it desynchronises every
  later query on that connection — the next query gets the previous one's tail.
  The client holds the error and returns it only after `ReadyForQuery` arrives.
* **`pg_hba.conf` is first-match-wins**, which is the whole trick to exercising
  more than one authentication method against one cluster: a per-role line for
  `md5` and one for `password`, both ahead of the `scram-sha-256` catch-all.
  `password_encryption` decides how the verifier is *stored*, so it has to be
  `md5` when the role is created for the `md5` method to work at all.
* **`test-server.sh start` must stop the old cluster before deleting its data
  dir.** Deleting it out from under a live postmaster leaves the process running
  and holding the port; the next `pg_ctl start` then fails with nothing but
  "could not start server".
