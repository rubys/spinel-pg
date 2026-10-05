# spinel: int64 -- PostgreSQL OIDs are unsigned 32-bit.
# Public result metadata over an injected transport, CRuby/native parity.
require "pg/client"

class TypeTransport
  def initialize(chunks)
    @chunks = chunks
    @index = 0
  end

  def write(data)
    data.bytesize
  end

  def read_some(max)
    return "" if @index >= @chunks.length
    value = @chunks[@index]
    @index += 1
    value
  end

  def close
    0
  end
end

def type_check(name, passed)
  raise "failed: " + name unless passed
  puts name + " true"
end

def type_message(kind, body)
  kind + PgWire.be32(body.bytesize + 4) + body
end

def type_ready
  type_message("Z", "I")
end

def type_description(names, oids)
  body = PgWire.be16(names.length)
  i = 0
  while i < names.length
    body = body + names[i] + PgWire.zero + PgWire.be32(0) + PgWire.be16(0) +
           PgWire.be32(oids[i]) + PgWire.be16(65535) + PgWire.be32(-1) + PgWire.be16(0)
    i += 1
  end
  type_message("T", body)
end

def type_client(replies)
  transport = TypeTransport.new([type_message("R", PgWire.be32(0)) + type_ready, replies])
  client = PgClientCore.new(transport, "reader", "fixture", "", "nonce")
  client.connect!
  client
end

def type_bad_index(result, index)
  begin
    result.ftype(index)
  rescue ArgumentError => error
    return error.message == "invalid field number " + index.to_s
  end
  false
end

# A NULL does not erase its type. Aliases do not determine the OID, and an
# unsigned OID must not become a negative number on its way to the public API.
description = type_description(["same", "same", "text", "custom"], [20, 16, 25, 3000000000])
row = type_message("D", PgWire.be16(4) + PgWire.be32(1) + "7" +
                   PgWire.be32(1) + "f" + PgWire.be32(-1) + PgWire.be32(1) + "x")
client = type_client(description + row + type_message("C", "SELECT 1" + PgWire.zero) + type_ready)
result = client.exec("SELECT 7::bigint AS same, false AS same, NULL::text, 'x'::custom")
type_check("simple_types", result.ftype(0) == 20 && result.ftype(1) == 16 && result.ftype(2) == 25)
type_check("unsigned_oid", result.ftype(3) == 3000000000)
type_check("null_type", result.getvalue(0, 2).nil? && result.ftype(2) == 25)
type_check("text_unchanged", result.getvalue(0, 0) == "7" && result.getvalue(0, 1) == "f")
type_check("negative_index", type_bad_index(result, -1))
type_check("past_last_index", type_bad_index(result, 4))

client = type_client(type_description(["value"], [1043]) + type_message("C", "SELECT 0" + PgWire.zero) + type_ready)
result = client.exec("SELECT 'x'::varchar AS value WHERE false")
type_check("simple_zero_rows", result.ntuples == 0 && result.nfields == 1 && result.ftype(0) == 1043)

# exec's documented last-result behavior must replace, not append, types.
client = type_client(description + row + type_message("C", "SELECT 1" + PgWire.zero) +
                     type_description(["last"], [16]) + type_message("C", "SELECT 0" + PgWire.zero) + type_ready)
result = client.exec("SELECT 7, false, NULL, 'x'; SELECT false AS last WHERE false")
type_check("last_description", result.nfields == 1 && result.ntuples == 0 && result.ftype(0) == 16 && type_bad_index(result, 1))

client = type_client(type_message("1", "") + type_message("2", "") + description + row +
                     type_message("C", "SELECT 1" + PgWire.zero) + type_ready)
result = client.exec_params("SELECT $1::bigint, false, NULL::text, 'x'::custom", ["7"])
type_check("bound_types", result.ftype(0) == 20 && result.ftype(1) == 16 && result.ftype(3) == 3000000000)

client = type_client(type_message("1", "") + type_message("2", "") + type_description(["value"], [20]) +
                     type_message("C", "SELECT 0" + PgWire.zero) + type_ready)
result = client.exec_params("SELECT $1::bigint AS value WHERE false", ["7"])
type_check("bound_zero_rows", result.ntuples == 0 && result.ftype(0) == 20)

# Prepare has no RowDescription; each execution describes its result even
# when it has no rows. Earlier PgResults keep their own metadata.
client = type_client(type_message("1", "") + type_ready +
                     type_message("2", "") + type_description(["value"], [16]) +
                     type_message("C", "SELECT 0" + PgWire.zero) + type_ready +
                     type_message("2", "") + type_description(["value"], [16]) +
                     type_message("C", "SELECT 0" + PgWire.zero) + type_ready +
                     type_message("3", "") + type_ready)
prepared = client.prepare("flag", "SELECT $1::boolean AS value WHERE false")
type_check("prepare_no_fields", prepared.nfields == 0 && type_bad_index(prepared, 0))
first = client.exec_prepared("flag", ["false"])
second = client.exec_prepared("flag", ["true"])
type_check("prepared_zero_rows", first.ntuples == 0 && first.ftype(0) == 16 && second.ftype(0) == 16)
closed = client.close_prepared("flag")
type_check("closed_no_fields", closed.nfields == 0 && type_bad_index(closed, 0))
type_check("retained_result", first.ftype(0) == 16 && second.ftype(0) == 16)

client = type_client(type_message("1", "") + type_message("2", "") + type_message("n", "") +
                     type_message("C", "UPDATE 0" + PgWire.zero) + type_ready)
result = client.exec_params("UPDATE empty SET value = $1", ["x"])
type_check("no_data", result.nfields == 0 && type_bad_index(result, 0))
