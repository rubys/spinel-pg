# The same statements run through spinel-pg and the pg gem oracle. The
# injected SQLSTATE cases check mapping, not concurrent deadlock detection.

def live_error_check(name, passed)
  raise "failed: " + name unless passed
  puts name + " true"
end

def live_error_sqls
  ["INSERT INTO sqlstate_child VALUES (1, 1, 'ok', 1)",
   "INSERT INTO sqlstate_child VALUES (2, 999, 'ok', 1)",
   "INSERT INTO sqlstate_child VALUES (2, 1, NULL, 1)",
   "INSERT INTO sqlstate_child VALUES (2, 1, 'ok', -1)",
   "SELEC 1", "SELECT 1 / 0",
   "INSERT INTO sqlstate_ranges VALUES ('[2,4)'::int4range)",
   "INSERT INTO sqlstate_child VALUES (2, 1, 'long', 1)", "SELECT 2147483648::integer",
   "SELECT 'bad'::integer", "CREATE DATABASE postgres",
   "DO $$BEGIN RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'serialization test'; END$$",
   "DO $$BEGIN RAISE EXCEPTION USING ERRCODE = '40P01', MESSAGE = 'deadlock test'; END$$",
   "DO $$BEGIN RAISE EXCEPTION USING ERRCODE = '55P03', MESSAGE = 'lock test'; END$$",
   "DO $$BEGIN RAISE EXCEPTION USING ERRCODE = '57014', MESSAGE = 'cancel test'; END$$",
   "DO $$BEGIN RAISE EXCEPTION USING ERRCODE = '23ZZZ', MESSAGE = 'unknown integrity code'; END$$",
   "DO $$BEGIN RAISE EXCEPTION USING ERRCODE = 'ZZ999', MESSAGE = 'unknown code'; END$$",
   "DO $$BEGIN RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'clé déjà présente', DETAIL = 'extra detail', HINT = 'try again', SCHEMA = 'public', TABLE = 'sqlstate_child', COLUMN = 'note', DATATYPE = 'varchar', CONSTRAINT = 'custom_constraint'; END$$",
   "SELECT sqlstate_internal()"]
end

def live_error_names
  ["UniqueViolation", "ForeignKeyViolation", "NotNullViolation", "CheckViolation", "SyntaxError", "DivisionByZero",
   "ExclusionViolation", "StringDataRightTruncation", "NumericValueOutOfRange", "InvalidTextRepresentation",
   "DuplicateDatabase", "TRSerializationFailure", "TRDeadlockDetected", "LockNotAvailable", "QueryCanceled",
   "IntegrityConstraintViolation", "ServerError", "UniqueViolation", "SyntaxError"]
end

def live_error_states
  ["23505", "23503", "23502", "23514", "42601", "22012", "23P01", "22001", "22003", "22P02", "42P04",
   "40001", "40P01", "55P03", "57014", "23ZZZ", "ZZ999", "23505", "42601"]
end

def live_error_fields
  [PG::PG_DIAG_SEVERITY, PG::PG_DIAG_SEVERITY_NONLOCALIZED, PG::PG_DIAG_SQLSTATE,
   PG::PG_DIAG_MESSAGE_PRIMARY, PG::PG_DIAG_MESSAGE_DETAIL, PG::PG_DIAG_MESSAGE_HINT,
   PG::PG_DIAG_STATEMENT_POSITION, PG::PG_DIAG_INTERNAL_POSITION, PG::PG_DIAG_INTERNAL_QUERY,
   PG::PG_DIAG_CONTEXT, PG::PG_DIAG_SCHEMA_NAME, PG::PG_DIAG_TABLE_NAME, PG::PG_DIAG_COLUMN_NAME,
   PG::PG_DIAG_DATATYPE_NAME, PG::PG_DIAG_CONSTRAINT_NAME, PG::PG_DIAG_SOURCE_FILE,
   PG::PG_DIAG_SOURCE_LINE, PG::PG_DIAG_SOURCE_FUNCTION]
end

# The optional diagnostic output is for comparison against pg on the same
# server: it includes all fields and nils, even source file/line/function.
def live_error_observe(label, error, name, state, diagnostics)
  # Spinel e5e8f794c's class.name cache can reuse a stale exception name.
  # class.to_s reads the actual class and also matches the pg gem.
  actual_name = error.class.to_s
  actual_state = error.result.error_field(PG::PG_DIAG_SQLSTATE).to_s
  if actual_name != "PG::" + name || actual_state != state
    raise label + ": expected PG::" + name + "/" + state + ", got " + actual_name + "/" + actual_state + ": " + error.message
  end
  puts label + " true"
  if diagnostics
    fields = live_error_fields
    values = [""]
    values.delete_at(0)
    i = 0
    while i < fields.length
      value = error.result.error_field(fields[i])
      if value.nil?
        values.push("nil")
      else
        values.push(value.to_s.inspect)
      end
      i = i + 1
    end
    puts label + " | " + error.class.to_s + " | " + values.join(" | ")
  end
end

def run_live_errors(client, diagnostics)
  client.exec("CREATE TABLE sqlstate_parent (id integer PRIMARY KEY)")
  client.exec("INSERT INTO sqlstate_parent VALUES (1)")
  client.exec("CREATE TABLE sqlstate_child (id integer PRIMARY KEY, parent_id integer REFERENCES sqlstate_parent, note varchar(2) NOT NULL, qty integer CHECK (qty > 0))")
  client.exec("INSERT INTO sqlstate_child VALUES (1, 1, 'ok', 1)")
  client.exec("CREATE TABLE sqlstate_ranges (span int4range, EXCLUDE USING gist (span WITH &&))")
  client.exec("INSERT INTO sqlstate_ranges VALUES ('[1,3)'::int4range)")
  client.exec("CREATE FUNCTION sqlstate_internal() RETURNS void LANGUAGE plpgsql AS $$BEGIN EXECUTE 'SELEC 1'; END$$")
  begin
    sqls = live_error_sqls
    names = live_error_names
    states = live_error_states
    # Each ordinary error must recover on the next request, on all three paths.
    mode = 0
    while mode < 3
      i = 0
      while i < sqls.length
        label = "error_" + mode.to_s + "_" + i.to_s
        caught = false
        prepared = false
        begin
          if mode == 0
            client.exec(sqls[i])
          elsif mode == 1
            client.exec_params(sqls[i], [])
          else
            # Parse can reject syntax or invalid literals; Bind planning and
            # Execute can also fail. The parameter cases below force Bind errors.
            client.prepare("error_case", sqls[i])
            prepared = true
            client.exec_prepared("error_case", [])
          end
        rescue PG::Error => error
          caught = true
          live_error_observe(label, error, names[i], states[i], diagnostics)
          field = error.result.error_field(PG::PG_DIAG_MESSAGE_PRIMARY).to_s
          # Both drivers' message formats include the primary message.
          live_error_check("message_" + mode.to_s + "_" + i.to_s, error.message.include?(field))
          if i == 0
            live_error_check("unique_fields_" + mode.to_s, error.result.error_field(PG::PG_DIAG_SCHEMA_NAME) == "public" &&
                              error.result.error_field(PG::PG_DIAG_TABLE_NAME) == "sqlstate_child" &&
                              error.result.error_field(PG::PG_DIAG_CONSTRAINT_NAME) == "sqlstate_child_pkey" &&
                              error.result.error_field(PG::PG_DIAG_MESSAGE_DETAIL) == "Key (id)=(1) already exists.")
          elsif i == 2
            live_error_check("null_fields_" + mode.to_s, error.result.error_field(PG::PG_DIAG_COLUMN_NAME) == "note")
          elsif i == 4
            live_error_check("syntax_position_" + mode.to_s, error.result.error_field(PG::PG_DIAG_STATEMENT_POSITION) == "1")
          elsif i == 17
            live_error_check("custom_fields_" + mode.to_s, error.result.error_field(PG::PG_DIAG_MESSAGE_PRIMARY) == "clé déjà présente" &&
                              error.result.error_field(PG::PG_DIAG_MESSAGE_HINT) == "try again" &&
                              error.result.error_field(PG::PG_DIAG_DATATYPE_NAME) == "varchar" &&
                              error.result.error_field(PG::PG_DIAG_CONSTRAINT_NAME) == "custom_constraint")
          elsif i == 18
            live_error_check("internal_fields_" + mode.to_s, error.result.error_field(PG::PG_DIAG_INTERNAL_POSITION) == "1" &&
                              error.result.error_field(PG::PG_DIAG_INTERNAL_QUERY) == "SELEC 1" &&
                              !error.result.error_field(PG::PG_DIAG_CONTEXT).nil?)
          end
        end
        raise "expected server error: " + label unless caught
        result = client.exec_params("SELECT 42", [])
        live_error_check("recovery_" + mode.to_s + "_" + i.to_s, result.getvalue(0, 0) == "42" &&
                          client.transaction_status == PG::PQTRANS_IDLE)
        if prepared
          client.exec("DEALLOCATE error_case")
        end
        i = i + 1
      end
      mode = mode + 1
    end

    # Invalid parameter text fails during Bind, after a successful Parse.
    client.prepare("sqlstate_bind", "SELECT $1::integer")
    mode = 0
    while mode < 2
      caught = false
      begin
        if mode == 0
          client.exec_params("SELECT $1::integer", ["bad"])
        else
          client.exec_prepared("sqlstate_bind", ["bad"])
        end
      rescue PG::Error => error
        caught = true
        live_error_observe("bind_" + mode.to_s, error, "InvalidTextRepresentation", "22P02", diagnostics)
      end
      raise "expected Bind error" unless caught
      live_error_check("bind_recovery_" + mode.to_s,
                       client.exec_prepared("sqlstate_bind", ["42"]).getvalue(0, 0) == "42" &&
                       client.transaction_status == PG::PQTRANS_IDLE)
      mode = mode + 1
    end
    client.exec("DEALLOCATE sqlstate_bind")

    # A completed SELECT must not hide a later error in the same batch (#9).
    caught = false
    begin
      client.exec("SELECT false; INSERT INTO sqlstate_child VALUES (1, 1, 'ok', 1); SELECT true")
    rescue PG::Error => error
      caught = true
      live_error_observe("batch_error", error, "UniqueViolation", "23505", diagnostics)
    end
    raise "expected batch error" unless caught
    live_error_check("batch_recovery", client.exec("SELECT 42").getvalue(0, 0) == "42" &&
                                       client.transaction_status == PG::PQTRANS_IDLE)

    # Rails identifies an expired prepared result with these two fields.
    client.exec("CREATE TEMP TABLE sqlstate_plan (id integer)")
    client.prepare("sqlstate_plan", "SELECT * FROM sqlstate_plan")
    client.exec("ALTER TABLE sqlstate_plan ADD COLUMN note text")
    caught = false
    begin
      client.exec_prepared("sqlstate_plan", [])
    rescue PG::Error => error
      caught = true
      live_error_observe("cached_plan", error, "FeatureNotSupported", "0A000", diagnostics)
      live_error_check("cached_plan_fields", error.result.result_error_field(PG::PG_DIAG_SQLSTATE) == "0A000" &&
                                            error.result.result_error_field(PG::PG_DIAG_SOURCE_FUNCTION) == "RevalidateCachedQuery")
    end
    raise "expected cached plan error" unless caught
    client.exec("DEALLOCATE sqlstate_plan; DROP TABLE sqlstate_plan")
    live_error_check("cached_plan_recovery", client.exec("SELECT 42").getvalue(0, 0) == "42" &&
                                             client.transaction_status == PG::PQTRANS_IDLE)

    client.exec("BEGIN")
    begin
      client.exec_params("INSERT INTO sqlstate_child VALUES (1, 1, 'ok', 1)", [])
      raise "expected transaction error"
    rescue PG::Error => error
      live_error_observe("transaction_error", error, "UniqueViolation", "23505", diagnostics)
      live_error_check("transaction_failed", client.transaction_status == PG::PQTRANS_INERROR)
    end
    begin
      client.exec("SELECT 1")
      raise "expected aborted transaction error"
    rescue PG::Error => error
      live_error_observe("transaction_aborted", error, "InFailedSqlTransaction", "25P02", diagnostics)
    end
    client.exec("ROLLBACK")
    live_error_check("transaction_recovered", client.exec("SELECT 42").getvalue(0, 0) == "42" &&
                      client.transaction_status == PG::PQTRANS_IDLE)
  ensure
    client.exec("DROP FUNCTION sqlstate_internal(); DROP TABLE sqlstate_ranges, sqlstate_child, sqlstate_parent")
  end
end
