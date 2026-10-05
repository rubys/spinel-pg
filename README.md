# pg (spinel-pg)

A pure spinel-Ruby PostgreSQL client — protocol v3, simple and extended
query, text results — over spinel's `sp_net` sockets. Sibling of
[spinel-redis](https://github.com/rubys/spinel-redis), same
architecture end to end: pure wire functions, a `try_next`/ivar
incremental parser, a client core over an injected transport duck
(dual-runtime testable), and a thin `sp_net` transport.

```ruby
require "pg"

conn = PG.connect("127.0.0.1", 5432, "mastodon", "app", "secret")
r = conn.exec("SELECT id, name FROM accounts ORDER BY id")
r.ntuples          # => 2
r.fields           # => ["id", "name"]
r.ftype(1)         # => 25       (PostgreSQL text type OID)
r.getvalue(0, 1)   # => "alice"    (nil for NULL)
r.cmd_tag          # => "SELECT 2"

# parameters travel apart from the SQL ($1, $2, ...); nil is NULL
r = conn.exec_params("SELECT name FROM accounts WHERE id = $1", ["1"])
r.getvalue(0, 0)   # => "alice"

conn.prepare("by_id", "SELECT name FROM accounts WHERE id = $1")
conn.exec_prepared("by_id", ["2"]).getvalue(0, 0)   # => "bob"
conn.close_prepared("by_id")

conn.transaction_status   # => PG::PQTRANS_IDLE (or _INTRANS, _INERROR)
```

A server error raises after the reply is drained through
ReadyForQuery, so the connection stays usable, and
`transaction_status` reports the server's state after it: on
`PG::PQTRANS_INERROR`, recover with `ROLLBACK` or `ROLLBACK TO
SAVEPOINT`. A FATAL error (the server is closing the session) raises
at once.

`ftype(column)` reports the PostgreSQL type OID from the result's
RowDescription, including zero-row results. Column indexes are zero-based.
Compatibility covers Integer indexes in the signed 32-bit range; within
that range, an index outside `0...nfields` raises `ArgumentError`, as in
the pg gem. The gem's index coercion (for example, Float or `to_int`) and
exception behavior for nil or integers outside that range are not mirrored.
Values still arrive as text or nil: interpreting the OID and converting
values belongs to the caller.

## Auth: trust, cleartext, SCRAM-SHA-256

SCRAM rides pure-Ruby SHA-256 / HMAC / PBKDF2 (`pg/scram.rb`) rather
than `sp_crypto`: every sp_crypto entry point is `const char *` with
strlen semantics, and SCRAM's intermediate keys are raw 32-byte digests
that routinely contain NULs — they'd silently truncate
(matz/spinel#1779 asks for explicit-length variants). Compiled by
spinel the pure version is native-code speed, and auth runs once per
connection, so PBKDF2's 4096 iterations don't matter. The crypto is
pinned to published vectors (FIPS 180-4, RFC 4231, the full RFC 7677
SCRAM exchange) in the dual-runtime parity lane, and the live lane
authenticates against a real PostgreSQL 17 with `--auth=scram-sha-256`
— including rejecting a wrong password.

MD5 auth is deliberately not implemented (ledgered; servers have
defaulted to SCRAM since PG 14).

## Tests

```sh
spin test    # wire, scram + client lanes also run under CRuby and must match
```

The live lanes (`live_test`, `live_scram_test`, `live_extended_test`)
initdb throwaway instances on private ports and tear them down; they need
`initdb`/`pg_ctl`/`postgres` on PATH (brew:
`/opt/homebrew/opt/postgresql@17/bin`). Snapshots committed.

The pg-gem oracle lane (replaying flows through the real `pg` gem, as
spinel-redis does with redis-rb) lights up once the gem is installed:
`gem install pg -- --with-pg-config=/opt/homebrew/opt/libpq/bin/pg_config`.

## v0.1 exclusion ledger

- **Extended query**: text parameters only, no parameter type OIDs
  (cast in the SQL where the server can't infer one), no statement
  cache.
- **Error fields**: a server error raises `"pg: SEVERITY: message"`;
  SQLSTATE, detail and the rest aren't exposed yet.
- **MD5 auth**, **TLS/sslmode** (sp_net TLS = matz/spinel#1054),
  **COPY** (`FROM STDIN` hangs), **LISTEN/NOTIFY**,
  **portals/cursors**, **binary format results**, **connection
  pooling**, **unix sockets**.
- Multi-statement `exec` strings: last result wins.
- `PG.connect` is positional; the gem's kwargs/URL forms come with the
  seam work.
- **Encodings other than UTF-8**: startup sets `client_encoding` to
  UTF8, SQL goes out as its bytes, and text comes back tagged UTF-8.
  `SET client_encoding` to anything else isn't supported, and an early
  startup error may hold non-UTF-8 bytes, still tagged UTF-8.

## Spinel notes

- matz/spinel#1778 — `String#include?` truncates at NUL bytes; tests
  use a byte-exact scan for wire assertions.
- matz/spinel#1779 — sp_crypto explicit-length variants (found here).
- The workaround idioms from spinel-redis carry over (`.to_s` at wire
  boundaries; assign-then-return; sequential statements). #1773/#1775
  themselves were fixed upstream same-day (spinel a7e42e90) — the
  shapes are kept for compatibility with pre-fix builds.
