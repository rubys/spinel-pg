# Structured errors over a scripted transport, CRuby / Spinel parity.
require "pg/client"

class ErrorTransport
  def initialize(chunks)
    @chunks = chunks
    @index = 0
  end

  def write(data)
    data.bytesize
  end

  def read_some(max)
    if @index >= @chunks.length
      raise "unexpected read past scripted reply"
    end
    chunk = @chunks[@index]
    @index = @index + 1
    chunk.b
  end

  def reads
    @index
  end

  def close
    0
  end
end

def error_check(name, passed)
  raise "failed: " + name unless passed
  puts name + " true"
end

def error_message(kind, body)
  kind + PgWire.be32(body.bytesize + 4) + body.b
end

def error_ready(status)
  error_message("Z", status)
end

def error_body(code)
  "SERROR" + PgWire.zero + "C" + code + PgWire.zero + "Mbad query" + PgWire.zero + PgWire.zero
end

def error_client(reply)
  transport = ErrorTransport.new([error_message("R", PgWire.be32(0)) + error_ready("I"), reply])
  client = PgClientCore.new(transport, "u", "d", "", "nonce")
  client.connect!
  client
end

# All documented byte tokens; order is deliberately unrelated to the constants.
codes = [PG::PG_DIAG_SEVERITY, PG::PG_DIAG_SEVERITY_NONLOCALIZED, PG::PG_DIAG_SQLSTATE,
         PG::PG_DIAG_MESSAGE_PRIMARY, PG::PG_DIAG_MESSAGE_DETAIL, PG::PG_DIAG_MESSAGE_HINT,
         PG::PG_DIAG_STATEMENT_POSITION, PG::PG_DIAG_INTERNAL_POSITION, PG::PG_DIAG_INTERNAL_QUERY,
         PG::PG_DIAG_CONTEXT, PG::PG_DIAG_SCHEMA_NAME, PG::PG_DIAG_TABLE_NAME, PG::PG_DIAG_COLUMN_NAME,
         PG::PG_DIAG_DATATYPE_NAME, PG::PG_DIAG_CONSTRAINT_NAME, PG::PG_DIAG_SOURCE_FILE,
         PG::PG_DIAG_SOURCE_LINE, PG::PG_DIAG_SOURCE_FUNCTION]
error_check("diagnostic_constants", codes == [83, 86, 67, 77, 68, 72, 80, 112, 113, 87, 115, 116, 99, 100, 110, 70, 76, 82])
values = ["ERROR", "ERROR", "23505", "clé déjà présente", "details\non two lines", "try again",
          "17", "3", "SELECT é", "context\nnext frame", "public", "users", "email", "text",
          "users_email_key", "nbtinsert.c", "666", "_bt_check_unique"]
body = ""
i = codes.length - 1
while i >= 0
  body = body + [codes[i]].pack("C*") + values[i].b + PgWire.zero
  i = i - 1
end
# Retain unknown future fields, and don't scan past the list terminator.
body = body + "zfuture field" + PgWire.zero + PgWire.zero + "Hignored" + PgWire.zero
reply = error_message("E", body) + error_message("N", "Mnotice" + PgWire.zero + PgWire.zero) + error_ready("I")
# Fragment every header and field across reads, including non-ASCII UTF-8.
chunks = [error_message("R", PgWire.be32(0)) + error_ready("I")]
i = 0
while i < reply.bytesize
  chunks.push(reply.byteslice(i, 7))
  i = i + 7
end
chunks.push(error_message("C", "UPDATE 0" + PgWire.zero) + error_ready("I"))
transport = ErrorTransport.new(chunks)
client = PgClientCore.new(transport, "u", "d", "", "nonce")
client.connect!
begin
  client.exec("INSERT")
  raise "expected unique violation"
rescue PG::UniqueViolation => error
  error_check("unique_hierarchy", error.is_a?(PG::IntegrityConstraintViolation) && error.is_a?(PG::ServerError) &&
                                    error.is_a?(PG::Error) && !error.is_a?(RuntimeError) && error.is_a?(StandardError))
  error_check("message_unchanged", error.message == "pg: ERROR: clé déjà présente" && error.error == error.message)
  result = error.result
  i = 0
  while i < codes.length
    field = result.error_field(codes[i])
    error_check("field_" + codes[i].to_s, field == values[i] && field.to_s.encoding.to_s == "UTF-8")
    i = i + 1
  end
  error_check("future_field", result.error_field(122) == "future field")
  error_check("field_alias", result.result_error_field(PG::PG_DIAG_SQLSTATE) == "23505")
  error_check("unknown_field", result.error_field(1).nil? && result.error_field(999).nil?)
  error_check("drained_before_raise", client.transaction_status == PG::PQTRANS_IDLE)
  client.exec("UPDATE")
  error_check("retained_diagnostics", result.error_field(PG::PG_DIAG_MESSAGE_DETAIL) == "details\non two lines")
end

# Exact pg class names: all Rails 8.1 translated codes plus common query errors.
states = ["22001", "22003", "22012", "22P02", "23502", "23503", "23505", "23514", "23P01",
          "25P02", "26000", "28P01", "40001", "40P01", "42601", "42703", "42P01", "42P04",
          "55P03", "57014", "57P01", "XX000"]
names = ["StringDataRightTruncation", "NumericValueOutOfRange", "DivisionByZero", "InvalidTextRepresentation",
         "NotNullViolation", "ForeignKeyViolation", "UniqueViolation", "CheckViolation", "ExclusionViolation",
         "InFailedSqlTransaction", "InvalidSqlStatementName", "InvalidPassword", "TRSerializationFailure",
         "TRDeadlockDetected", "SyntaxError", "UndefinedColumn", "UndefinedTable", "DuplicateDatabase",
         "LockNotAvailable", "QueryCanceled", "AdminShutdown", "InternalError"]
i = 0
while i < states.length
  client = error_client(error_message("E", error_body(states[i])) + error_ready("I"))
  raised = false
  begin
    client.exec_params("bad query", [])
  rescue PG::Error => error
    raised = error.class.to_s == "PG::" + names[i] && error.result.error_field(PG::PG_DIAG_SQLSTATE) == states[i]
  end
  error_check("class_" + states[i], raised)
  i = i + 1
end

# Unknown codes use the included two-byte class, then ServerError.
states = ["0AZZZ", "08ZZZ", "22ZZZ", "23ZZZ", "25ZZZ", "26ZZZ", "28ZZZ", "3DZZZ", "40ZZZ", "42ZZZ",
          "53ZZZ", "55ZZZ", "57ZZZ", "XXZZZ", "99ZZZ", "P0001", "", "x"]
names = ["FeatureNotSupported", "ConnectionException", "DataException", "IntegrityConstraintViolation",
         "InvalidTransactionState", "InvalidSqlStatementName", "InvalidAuthorizationSpecification", "InvalidCatalogName",
         "TransactionRollback", "SyntaxErrorOrAccessRuleViolation", "InsufficientResources", "ObjectNotInPrerequisiteState",
         "OperatorIntervention", "InternalError", "ServerError", "ServerError", "ServerError", "ServerError"]
i = 0
while i < states.length
  client = error_client(error_message("E", error_body(states[i])) + error_ready("I"))
  raised = false
  begin
    client.exec("bad query")
  rescue PG::ServerError => error
    raised = error.class.to_s == "PG::" + names[i] && error.result.error_field(PG::PG_DIAG_SQLSTATE) == states[i]
  end
  error_check("fallback_" + i.to_s, raised)
  i = i + 1
end

client = error_client(error_message("E", "D" + PgWire.zero + PgWire.zero) + error_ready("I"))
begin
  client.exec("missing fields")
  raise "expected server error"
rescue PG::ServerError => error
  error_check("missing_fields", error.class.to_s == "PG::ServerError" && error.result.error_field(PG::PG_DIAG_SQLSTATE).nil? &&
                                error.result.error_field(PG::PG_DIAG_SEVERITY).nil? && error.message == "pg: : ")
  error_check("empty_field_present", error.result.error_field(PG::PG_DIAG_MESSAGE_DETAIL) == "" &&
                                    error.result.error_field(PG::PG_DIAG_MESSAGE_HINT).nil?)
end

# Shared reader paths: deferred prepare / execute / close errors and tx state.
client = error_client(error_message("E", error_body("42601")) + error_ready("I") +
                      error_message("E", error_body("23505")) + error_ready("E") +
                      error_message("E", error_body("26000")) + error_ready("E") +
                      error_message("C", "ROLLBACK" + PgWire.zero) + error_ready("I"))
begin
  client.prepare("bad", "SELEC")
  raise "expected Parse error"
rescue PG::SyntaxError => error
  error_check("prepare_error", error.is_a?(PG::SyntaxErrorOrAccessRuleViolation) && client.transaction_status == PG::PQTRANS_IDLE)
end
begin
  client.exec_prepared("insert", ["dup"])
  raise "expected Execute error"
rescue PG::UniqueViolation => error
  error_check("prepared_error", client.transaction_status == PG::PQTRANS_INERROR)
end
begin
  client.close_prepared("absent")
  raise "expected Close error"
rescue PG::InvalidSqlStatementName => error
  error_check("close_error", error.result.error_field(PG::PG_DIAG_SQLSTATE) == "26000")
end
client.exec("ROLLBACK")
error_check("rollback_recovery", client.transaction_status == PG::PQTRANS_IDLE)

# FATAL/PANIC have no ReadyForQuery. The untranslated V wins over S,
# with S as the old-server fallback. An attempted extra read fails the test.
severities = ["FATAL", "FATALE", "PANIC"]
nonlocalized = ["", "FATAL", "PANIC"]
i = 0
while i < severities.length
  body = "S" + severities[i] + PgWire.zero + "C57P01" + PgWire.zero + "Mbye" + PgWire.zero
  if nonlocalized[i] != ""
    body = body + "V" + nonlocalized[i] + PgWire.zero
  end
  client = error_client(error_message("E", body + PgWire.zero))
  raised = false
  begin
    client.exec_params("query", [])
  rescue PG::AdminShutdown => error
    raised = error.result.error_field(PG::PG_DIAG_SEVERITY) == severities[i] &&
             client.transaction_status == PG::PQTRANS_UNKNOWN && error.message == "pg: " + severities[i] + ": bye"
  end
  error_check("immediate_" + i.to_s, raised)
  i = i + 1
end

body = "SFATAL" + PgWire.zero + "C28P01" + PgWire.zero + "Mbad password" + PgWire.zero + PgWire.zero
transport = ErrorTransport.new([error_message("E", body)])
client = PgClientCore.new(transport, "u", "d", "wrong", "nonce")
raised = false
begin
  client.connect!
rescue PG::InvalidPassword => error
  raised = error.is_a?(PG::InvalidAuthorizationSpecification) && error.result.error_field(PG::PG_DIAG_SQLSTATE) == "28P01"
end
error_check("startup_error", raised && !client.ready? && client.transaction_status == PG::PQTRANS_UNKNOWN)

# Rails' generic translation leaves RuntimeError untouched, so PG errors
# must inherit StandardError directly, as in pg. A preceding RuntimeError
# rescue must not intercept server errors either.
client = error_client(error_message("E", error_body("23505")) + error_ready("I"))
raised = false
begin
  client.exec("duplicate")
rescue RuntimeError
  raised = false
rescue PG::Error => error
  raised = error.result.error_field(PG::PG_DIAG_SQLSTATE) == "23505"
end
error_check("runtime_rescue_does_not_intercept", raised)

client = error_client(error_message("E", error_body("42601")) + error_ready("I"))
wrapped = false
begin
  client.exec("syntax error")
rescue PG::Error => error
  # The decision in Rails 8.1 AbstractAdapter#translate_exception.
  case error
  when RuntimeError
    wrapped = false
  else
    wrapped = true
  end
end
error_check("rails_fallback_wraps_server_error", wrapped)
