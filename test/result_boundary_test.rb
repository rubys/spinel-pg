# Last-result boundaries over an injected transport, CRuby/native parity.
# The COMMIT and UPDATE replies reproduce dchuk's report in #8.
require "pg/client"

class BoundaryTransport
  def initialize(reply)
    @reply = reply
  end

  def write(data)
    data.bytesize
  end

  def read_some(max)
    reply = @reply
    @reply = ""
    reply
  end
end

def boundary_check(name, passed)
  raise "failed: " + name unless passed
  puts name + " true"
end

def boundary_message(kind, body)
  kind + PgWire.be32(body.bytesize + 4) + body
end

def boundary_description(name, oid)
  body = PgWire.be16(1) + name + PgWire.zero + PgWire.be32(0) +
         PgWire.be16(0) + PgWire.be32(oid) + PgWire.be16(1) + PgWire.be32(-1) + PgWire.be16(0)
  boundary_message("T", body)
end

def boundary_complete(tag)
  boundary_message("C", tag + PgWire.zero)
end

def boundary_client(reply)
  client = PgClientCore.new(BoundaryTransport.new(reply), "reader", "fixture", "", "nonce")
  client
end

def boundary_no_type(result)
  begin
    result.ftype(0)
  rescue ArgumentError => error
    return error.message == "invalid field number 0"
  end
  false
end

ready = boundary_message("Z", "I")
description = boundary_description("flag", 16)
row = boundary_message("D", PgWire.be16(1) + PgWire.be32(1) + "f")
selected = description + row + boundary_complete("SELECT 1")

["COMMIT", "UPDATE 0"].each do |last_tag|
  reply = selected + boundary_complete(last_tag) + ready
  sql = "SELECT false; UPDATE widgets SET flag = true WHERE false"
  if last_tag == "COMMIT"
    reply = boundary_complete("BEGIN") + reply
    sql = "BEGIN; SELECT false; COMMIT"
  end
  result = boundary_client(reply).exec(sql)
  boundary_check(last_tag + "_empty", result.cmd_tag == last_tag && result.nfields == 0 && result.ntuples == 0)
  boundary_check(last_tag + "_values", result.fields.length == 0 && result.getvalue(0, 0).nil?)
  boundary_check(last_tag + "_types", boundary_no_type(result))
end

# Notices and parameter changes do not start a result, including after the
# final CommandComplete. A later zero-row SELECT keeps its own metadata.
notice = boundary_message("N", "SNOTICE" + PgWire.zero + "Mhello" + PgWire.zero + PgWire.zero)
parameter = boundary_message("S", "application_name" + PgWire.zero + "fixture" + PgWire.zero)
client = boundary_client(selected + notice + parameter + boundary_description("last", 20) +
                         boundary_complete("SELECT 0") + notice + parameter + ready)
result = client.exec("SELECT false; SELECT 7::bigint AS last WHERE false")
boundary_check("last_zero_rows", result.cmd_tag == "SELECT 0" && result.ntuples == 0 && result.nfields == 1)
boundary_check("last_zero_metadata", result.fields[0] == "last" && result.ftype(0) == 20 && result.getvalue(0, 0).nil?)

client = boundary_client(selected + notice + parameter + ready)
result = client.exec("SELECT false; ;")
boundary_check("last_select", result.cmd_tag == "SELECT 1" && result.getvalue(0, 0) == "f" && result.ftype(0) == 16)

# Notifications may arrive after CommandComplete, just before ReadyForQuery.
# Ignoring their payload must not discard a completed result or its tag.
notification = boundary_message("A", PgWire.be32(123) + "fixture" + PgWire.zero + "hello" + PgWire.zero)
client = boundary_client(selected + notification + notice + parameter + ready)
result = client.exec("SELECT false")
boundary_check("notification_select", result.cmd_tag == "SELECT 1" && result.nfields == 1 &&
                                      result.fields[0] == "flag" && result.ntuples == 1 &&
                                      result.getvalue(0, 0) == "f" && result.ftype(0) == 16)
client = boundary_client(description + boundary_complete("SELECT 0") + notification + ready)
result = client.exec("SELECT false WHERE false")
boundary_check("notification_zero", result.cmd_tag == "SELECT 0" && result.nfields == 1 &&
                                    result.ntuples == 0 && result.ftype(0) == 16)
client = boundary_client(selected + boundary_complete("UPDATE 0") + notification + ready)
result = client.exec("SELECT false; UPDATE widgets SET flag = true WHERE false")
boundary_check("notification_command", result.cmd_tag == "UPDATE 0" && result.nfields == 0 &&
                                       result.ntuples == 0 && boundary_no_type(result))

# EmptyQueryResponse has no tag or metadata. A synthetic second result also
# checks that the shared reader resets the previous tag at this boundary.
client = boundary_client(selected + boundary_message("I", "") + ready)
result = client.exec("")
boundary_check("empty_response", result.cmd_tag == "" && result.nfields == 0 && result.ntuples == 0)
boundary_check("empty_response_type", boundary_no_type(result) && result.getvalue(0, 0).nil?)

# Replacing a NULL row must reset both flat values and parallel null flags.
null_row = boundary_message("D", PgWire.be16(1) + PgWire.be32(-1))
client = boundary_client(description + null_row + boundary_complete("SELECT 1") +
                         boundary_complete("UPDATE 0") + selected + ready)
result = client.exec("SELECT NULL::boolean; UPDATE widgets SET flag = true WHERE false; SELECT false")
boundary_check("last_nonnull", result.ntuples == 1 && result.getvalue(0, 0) == "f" && result.ftype(0) == 16)

# Each extended call has only one command. NoData and EmptyQueryResponse
# must stay empty, and later calls must leave retained PgResults intact.
parsed = boundary_message("1", "")
bound = boundary_message("2", "")
no_data = boundary_message("n", "")
client = boundary_client(parsed + bound + selected + notification + ready +
                         parsed + ready + bound + selected + notification + ready)
result = client.exec_params("SELECT $1::boolean AS flag", ["false"])
boundary_check("notification_bound", result.cmd_tag == "SELECT 1" && result.ntuples == 1 &&
                                     result.getvalue(0, 0) == "f" && result.ftype(0) == 16)
client.prepare("flag", "SELECT $1::boolean AS flag")
result = client.exec_prepared("flag", ["false"])
boundary_check("notification_prepared", result.cmd_tag == "SELECT 1" && result.ntuples == 1 &&
                                        result.getvalue(0, 0) == "f" && result.ftype(0) == 16)

client = boundary_client(selected + ready + parsed + bound + no_data + boundary_complete("UPDATE 0") + ready +
                         parsed + bound + no_data + boundary_message("I", "") + ready +
                         parsed + ready + bound + no_data + boundary_complete("COMMIT") + ready +
                         bound + no_data + boundary_message("I", "") + ready +
                         boundary_message("3", "") + ready)
retained = client.exec("SELECT false")
result = client.exec_params("UPDATE widgets SET flag = $1::boolean WHERE false", ["true"])
boundary_check("bound_no_data", result.cmd_tag == "UPDATE 0" && result.nfields == 0 && result.ntuples == 0 && boundary_no_type(result))
result = client.exec_params("", [])
boundary_check("bound_empty", result.cmd_tag == "" && result.nfields == 0 && result.ntuples == 0 && boundary_no_type(result))
result = client.prepare("last", "COMMIT")
boundary_check("prepare_empty", result.cmd_tag == "" && result.nfields == 0 && boundary_no_type(result))
result = client.exec_prepared("last", [])
boundary_check("prepared_no_data", result.cmd_tag == "COMMIT" && result.nfields == 0 && result.ntuples == 0 && boundary_no_type(result))
result = client.exec_prepared("empty", [])
boundary_check("prepared_empty", result.cmd_tag == "" && result.nfields == 0 && result.ntuples == 0 && boundary_no_type(result))
result = client.close_prepared("last")
boundary_check("close_empty", result.cmd_tag == "" && result.nfields == 0 && boundary_no_type(result))
boundary_check("retained_result", retained.fields[0] == "flag" && retained.ntuples == 1 && retained.getvalue(0, 0) == "f" && retained.ftype(0) == 16)

# An error after a SELECT raises after ReadyForQuery, rather than returning
# the SELECT's data, and a subsequent command starts with an empty result.
error = boundary_message("E", "SERROR" + PgWire.zero + "C22012" + PgWire.zero +
                         "Mdivision by zero" + PgWire.zero + PgWire.zero)
client = boundary_client(selected + error + ready + boundary_complete("UPDATE 0") + ready)
raised = false
begin
  client.exec("SELECT false; SELECT 1 / 0")
rescue => e
  raised = e.message == "pg: ERROR: division by zero"
end
boundary_check("batch_error", raised && client.transaction_status == PG::PQTRANS_IDLE)
result = client.exec("UPDATE widgets SET flag = true WHERE false")
boundary_check("error_recovers", result.cmd_tag == "UPDATE 0" && result.nfields == 0 && result.ntuples == 0 && boundary_no_type(result))
