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
