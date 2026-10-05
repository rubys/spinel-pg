# Query client over an injected transport duck (write / read_some /
# close) — same architecture as spinel-redis's RedisClientCore: the
# protocol logic tests dual-runtime against a scripted transport, the
# real sp_net transport stays in the compiled-only lanes.
#
# Simple query, plus the extended protocol for parameters and named
# prepared statements; text results either way. COPY / notifications
# are ledgered in the README.
require "pg/wire"
require "pg/scram"
require "pg/errors"

# transaction_status values, as the pg gem names them (ACTIVE never
# shows: a call returns only once ReadyForQuery has arrived).
module PG
  PQTRANS_IDLE = 0
  PQTRANS_ACTIVE = 1
  PQTRANS_INTRANS = 2
  PQTRANS_INERROR = 3
  PQTRANS_UNKNOWN = 4
end

# One query's result. Storage is flat and monomorphic — values in one
# StrArray with a parallel null-flag IntArray — and nil appears only at
# the getvalue edge (the redis-rb-proven String|nil contract).
class PgResult
  def initialize(fields, values, nulls, tag, types)
    @fields = fields
    @values = values
    @nulls = nulls
    @tag = tag
    @types = types
  end

  def fields
    @fields
  end

  def nfields
    @fields.length
  end

  # PostgreSQL type OID for a zero-based column, as in the pg gem.
  # RowDescription carries it even when the result contains no rows.
  def ftype(col)
    if col < 0 || col >= @fields.length
      raise ArgumentError, "invalid field number " + col.to_s
    end
    @types[col]
  end

  def ntuples
    if @fields.length == 0
      return 0
    end
    @values.length / @fields.length
  end

  def cmd_tag
    @tag
  end

  def getvalue(row, col)
    idx = row * @fields.length + col
    if idx < 0 || idx >= @values.length
      return nil
    end
    if @nulls[idx] == 1
      return nil
    end
    @values[idx]
  end
end

class PgClientCore
  def initialize(transport, user, database, password, scram_nonce)
    @t = transport
    @user = user
    @database = database
    @password = password
    @nonce = scram_nonce
    @parser = PgWireParser.new
    @ready = false
    @status = PG::PQTRANS_UNKNOWN
  end

  def ready?
    @ready
  end

  # From the latest ReadyForQuery: PG::PQTRANS_IDLE, _INTRANS, or
  # _INERROR (a failed transaction block; ROLLBACK, or ROLLBACK TO a
  # savepoint, gets out of it). _UNKNOWN before startup and once the
  # connection is closed or lost.
  def transaction_status
    @status
  end

  def close
    @t.write(PgWire.terminate)
    @t.close
    @status = PG::PQTRANS_UNKNOWN
  end

  # -- plumbing ----------------------------------------------------------

  def read_msg
    while true
      if @parser.try_next
        return @parser.msg
      end
      chunk = @t.read_some(65536)
      if chunk.bytesize == 0
        @status = PG::PQTRANS_UNKNOWN
        raise "pg: connection lost"
      end
      @parser.feed(chunk)
    end
  end

  def raise_error(body)
    PG.raise_server_error(body)
  end

  # FATAL and PANIC end the session: the server closes the connection
  # without a ReadyForQuery. "V" is the untranslated severity.
  def session_ending?(body)
    sev = PgDecode.error_field(body, "V")
    if sev == ""
      sev = PgDecode.error_field(body, "S")
    end
    sev == "FATAL" || sev == "PANIC"
  end

  def track_status(body)
    s = PgDecode.ready_status(body)
    if s == "I"
      @status = PG::PQTRANS_IDLE
    elsif s == "T"
      @status = PG::PQTRANS_INTRANS
    elsif s == "E"
      @status = PG::PQTRANS_INERROR
    else
      @status = PG::PQTRANS_UNKNOWN
    end
  end

  # -- startup / auth ------------------------------------------------------

  # Drive startup to ReadyForQuery. Handles trust (immediate ok),
  # cleartext password, and SCRAM-SHA-256. MD5 is deliberately not
  # implemented (ledgered; modern servers default to SCRAM).
  def connect!
    @t.write(PgWire.startup(@user, @database))
    scram = PgScram.new("", @password, @nonce)
    while true
      m = read_msg
      if m.kind == "R"
        code = PgDecode.auth_code(m.body)
        if code == 0
          # authenticated; fall through to parameter/ready messages
        elsif code == 3
          @t.write(PgWire.cleartext_password(@password))
        elsif code == 10
          mechs = PgDecode.sasl_mechanisms(m.body)
          if !mechs.include?("SCRAM-SHA-256")
            raise "pg: server offers no supported SASL mechanism (" + mechs + ")"
          end
          @t.write(PgWire.sasl_initial("SCRAM-SHA-256", scram.client_first))
        elsif code == 11
          final = scram.client_final(PgDecode.sasl_data(m.body))
          if final.bytesize == 0
            raise "pg: " + scram.error
          end
          @t.write(PgWire.sasl_response(final))
        elsif code == 12
          if !scram.verify_server_final(PgDecode.sasl_data(m.body))
            raise "pg: server signature verification failed"
          end
        elsif code == 5
          raise "pg: md5 auth not supported (configure scram-sha-256 or password)"
        else
          raise "pg: unsupported auth request code " + code.to_s
        end
      elsif m.kind == "E"
        raise_error(m.body)
      elsif m.kind == "Z"
        track_status(m.body)
        @ready = true
        return 0
      end
      # "S" ParameterStatus / "K" BackendKeyData / "N" notices: ignored
    end
  end

  # -- queries ---------------------------------------------------------------

  # Simple query, text results. Multi-statement strings work (last
  # result wins — enough for v0.1; ledgered).
  def exec(sql)
    @t.write(PgWire.query(sql))
    r = read_result
    r
  end

  # Extended query through the unnamed statement: the parameters travel
  # apart from the SQL ($1, $2, ...), so nothing is quoted or
  # interpolated. nil is SQL NULL; other values go as their to_s.
  def exec_params(sql, params)
    @t.write(PgWire.parse("", sql.to_s) + portal_messages("", params))
    r = read_result
    r
  end

  # Named prepared statement: parsed once, then run any number of times
  # with exec_prepared (no Parse). The result has no rows.
  def prepare(name, sql)
    @t.write(PgWire.parse(name.to_s, sql.to_s) + PgWire.sync)
    r = read_result
    r
  end

  def exec_prepared(name, params)
    @t.write(portal_messages(name.to_s, params))
    r = read_result
    r
  end

  # Frees a prepared statement on the server (the protocol's Close; same
  # effect as DEALLOCATE).
  def close_prepared(name)
    @t.write(PgWire.close("S", name.to_s) + PgWire.sync)
    r = read_result
    r
  end

  # Bind `statement` to the unnamed portal, describe it (for the field
  # names), run it to completion, Sync: the caller sends it all in one
  # write. On an error the server skips to the Sync and answers
  # ReadyForQuery, so read_result's drain-then-raise leaves the
  # connection ready for the next call.
  def portal_messages(statement, params)
    PgWire.bind("", statement, params) + PgWire.describe("P", "") + PgWire.execute("", 0) + PgWire.sync
  end

  # One result, read through ReadyForQuery. An ErrorResponse raises only
  # once ReadyForQuery is in, so the next call starts on a message
  # boundary; one that ends the session raises at once.
  def read_result
    fields = [""]
    fields.delete_at(0)
    types = [0]
    types.delete_at(0)
    values = [""]
    values.delete_at(0)
    nulls = [0]
    nulls.delete_at(0)
    tag = ""
    err_body = ""
    failed = false
    complete = false
    while true
      m = read_msg
      # Keep the completed result through asynchronous messages and ReadyForQuery,
      # but start fresh when the next command's reply arrives.
      if complete && m.kind != "Z" && m.kind != "N" && m.kind != "S" && m.kind != "A"
        # Fresh typed arrays avoid shifting every accumulated cell on reset.
        fields = [""]
        fields.delete_at(0)
        types = [0]
        types.delete_at(0)
        values = [""]
        values.delete_at(0)
        nulls = [0]
        nulls.delete_at(0)
        tag = ""
        complete = false
      end
      if m.kind == "T"
        fields = PgDecode.field_names(m.body)
        types = PgDecode.field_types(m.body)
        values = [""]
        values.delete_at(0)
        nulls = [0]
        nulls.delete_at(0)
      elsif m.kind == "D"
        row = PgDecode.row_values(m.body, "")
        # Parallel null flags: row_values hands back "" for NULL with a
        # second pass marking which were genuinely null.
        flags = PgDecode.row_null_flags(m.body)
        i = 0
        while i < row.length
          values.push(row[i])
          nulls.push(flags[i])
          i = i + 1
        end
      elsif m.kind == "C"
        tag = PgDecode.command_tag(m.body)
        complete = true
      elsif m.kind == "I"
        complete = true
      elsif m.kind == "E"
        err_body = m.body
        failed = true
        if session_ending?(m.body)
          @status = PG::PQTRANS_UNKNOWN
          raise_error(m.body)
        end
      elsif m.kind == "Z"
        track_status(m.body)
        if failed
          raise_error(err_body)
        end
        return PgResult.new(fields, values, nulls, tag, types)
      end
      # "N" notices / "S" parameter changes / "A" notifications: ignored.
      # So are replies with no result data: "1" ParseComplete, "2" BindComplete, "3"
      # CloseComplete, "n" NoData.
    end
  end
end
