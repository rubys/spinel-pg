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

`ftype(column)` reports the PostgreSQL type OID from the result's
RowDescription, including zero-row results. Column indexes are zero-based.
Compatibility covers Integer indexes in the signed 32-bit range; within
that range, an index outside `0...nfields` raises `ArgumentError`, as in
the pg gem. The gem's index coercion (for example, Float or `to_int`) and
exception behavior for nil or integers outside that range are not mirrored.
Values still arrive as text or nil: interpreting the OID and converting
values belongs to the caller.

## Server errors

Server errors raise `PG::ServerError` subclasses with the same names and
server hierarchy as the pg gem's included classes. Shared adapter code can
read SQLSTATE and diagnostics through the gem's access path:

```ruby
begin
  conn.exec_params("INSERT INTO accounts (id) VALUES ($1)", ["1"])
rescue PG::Error => e
  state = e.result.error_field(PG::PG_DIAG_SQLSTATE)           # "23505"
  detail = e.result.error_field(PG::PG_DIAG_MESSAGE_DETAIL)
  constraint = e.result.error_field(PG::PG_DIAG_CONSTRAINT_NAME)
  # Map state to the application's exception; no message matching needed.
end
```

Every ErrorResponse field is retained, including unknown future tokens.
`error_field` takes the integer byte identifier, as in libpq; all 18
`PG::PG_DIAG_*` constants have the pg gem's names and values. Missing fields
return nil, present empty fields return `""`, and values are UTF-8 strings.
`result_error_field` is an alias spelling. The attached `PgErrorResult`
provides diagnostics, rather than the gem's complete `PG::Result` interface.
The exception's message remains `"pg: SEVERITY: message"`; `error` also
returns that message. Detail, hint and positions are accessed as fields.

All SQLSTATE codes Rails 8.1's PostgreSQL adapter translates have specific
classes, along with common query errors:

| SQLSTATE | PG class | SQLSTATE | PG class |
| --- | --- | --- | --- |
| 22001 | StringDataRightTruncation | 22003 | NumericValueOutOfRange |
| 22012 | DivisionByZero | 22P02 | InvalidTextRepresentation |
| 23502 | NotNullViolation | 23503 | ForeignKeyViolation |
| 23505 | UniqueViolation | 23514 | CheckViolation |
| 23P01 | ExclusionViolation | 25P02 | InFailedSqlTransaction |
| 40001 | TRSerializationFailure | 40P01 | TRDeadlockDetected |
| 42601 | SyntaxError | 42703 | UndefinedColumn |
| 42P01 | UndefinedTable | 42P04 | DuplicateDatabase |
| 55P03 | LockNotAvailable | 57014 | QueryCanceled |
| 57P01 | AdminShutdown | | |

Other codes fall back by their first two bytes: `0A` FeatureNotSupported,
`08` ConnectionException, `22` DataException, `23`
IntegrityConstraintViolation, `25` InvalidTransactionState, `26`
InvalidSqlStatementName, `28` InvalidAuthorizationSpecification (with
`28P01` InvalidPassword), `3D` InvalidCatalogName, `40` TransactionRollback,
`42` SyntaxErrorOrAccessRuleViolation, `53` InsufficientResources, `55`
ObjectNotInPrerequisiteState, `57` OperatorIntervention, and `XX`
InternalError. An unrecognized class or missing SQLSTATE uses
`PG::ServerError`. This is a subset of the gem's SQLSTATE class catalog.

`PG::Error` inherits directly from `StandardError`, as in pg. This matters
to Rails: its generic exception translation leaves `RuntimeError` unchanged
instead of wrapping an unmapped SQLSTATE in `ActiveRecord::StatementInvalid`.
Server errors no longer match a legacy `rescue RuntimeError`; change those
handlers to `rescue PG::Error` (or `StandardError` for a general handler).
An earlier `rescue RuntimeError` will not intercept a later `rescue PG::Error`.
Bare rescues still catch server errors. Transport and local validation
failures retain their existing exceptions.

This supplies shared SQLSTATE mapping, not a drop-in Rails adapter. Rails'
cached-plan check can use `result_error_field` with SQLSTATE `0A000` and
source function `RevalidateCachedQuery`. Its connection-failure paths still
need `PG::ConnectionBad` and pg's transport errors; its warning path needs
`set_notice_receiver` and `PG::Result::PG_DIAG_*`. Those APIs are not supplied.
The missing-SQLSTATE fallback here is `PG::ServerError`, while pg's result
lookup uses `PG::UnableToSend`. Startup errors also differ: this client
retains their server diagnostics; pg raises `PG::ConnectionBad` without a
result. Session-ending query errors can also become `PG::ConnectionBad`
without a result in pg, while this client retains the server's SQLSTATE.
Exception constructors and the gem's `connection` accessor are not mirrored,
and messages retain the format described above.

A server error raises after the reply is drained through ReadyForQuery, so
the connection stays usable. `transaction_status` reports the server's
state: on `PG::PQTRANS_INERROR`, recover with `ROLLBACK` or `ROLLBACK TO
SAVEPOINT`. FATAL and PANIC errors raise at once without waiting for
ReadyForQuery; non-localized severity (`V`) decides, with `S` as the fallback.

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

The live lanes (`live_test`, `live_scram_test`, `live_extended_test`,
`live_errors_test`)
initdb throwaway instances on private ports and tear them down; they need
`initdb`/`pg_ctl`/`postgres` on PATH (brew:
`/opt/homebrew/opt/postgresql@17/bin`). Snapshots committed.

The structured-error cases in `test/support/error_cases.rb` also run through
the pg gem: require that file and call `run_live_errors(connection, true)`
against a disposable UTF8/C-locale database. It prints classes and all 18
diagnostic fields for comparison with spinel-pg on the same server. The
serialization, deadlock, lock and cancellation cases inject SQLSTATE with
`RAISE`; the other violations use real failing statements. To install the
oracle: `gem install pg -- --with-pg-config=/opt/homebrew/opt/libpq/bin/pg_config`.

## v0.1 exclusion ledger

- **Extended query**: text parameters only, no parameter type OIDs
  (cast in the SQL where the server can't infer one), no statement
  cache.
- **Error compatibility**: a subset of the gem's SQLSTATE classes;
  diagnostic results expose fields, not the full `PG::Result` API. Messages
  keep the client's existing format, and local/transport errors remain untyped.
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
- On Spinel e5e8f794c, repeated exception `class.name` reads can report a
  stale name after storage is reused; `class.to_s` works. Error tests use
  `class.to_s` for the pg-gem comparison.
- On that compiler, use `rescue PG::Error => e` before calling `e.result`,
  as in the example above. A bare rescue or `rescue StandardError => e`
  dispatches `result` to a built-in exception accessor and can return nil;
  an `is_a?(PG::Error)` guard does not fix that dispatch. Shared adapter code
  must enter diagnostic handling through the typed rescue. Unmodified Rails
  also uses generic rescues and `class.name`, so it needs these workarounds.
- The workaround idioms from spinel-redis carry over (`.to_s` at wire
  boundaries; assign-then-return; sequential statements). #1773/#1775
  themselves were fixed upstream same-day (spinel a7e42e90) — the
  shapes are kept for compatibility with pre-fix builds.
