# Extended query against a real PostgreSQL, spinel-only (committed
# snapshot), same shape as live_test: the test initdbs a throwaway
# instance (UTF8, C locale) on a private port and tears it down. Needs
# initdb/pg_ctl/postgres on PATH. Unlike live_test it stops if the
# instance doesn't start (rather than talk to whatever else holds the
# port), and stops it even when a query raises.
require "pg"

module XqShell
  ffi_func :sp_net_shell_capture, [:str, :int], :binstr
end

def xq_connect_retry(port, db, user, password)
  attempts = 0
  while true
    begin
      c = PG.connect("127.0.0.1", port, db, user, password)   # matz/spinel#1775: assign-then-return
      return c
    rescue
      attempts = attempts + 1
      if attempts > 50
        raise "live: postgres did not come up on " + port.to_s
      end
      XqShell.sp_net_shell_capture("sleep 0.2", 16)
    end
  end
end

def xq_no_type(result)
  begin
    result.ftype(0)
  rescue ArgumentError => e
    return e.message == "invalid field number 0"
  end
  false
end

DIR = "/tmp/spinel-pg-live-extended"
# Stop the server; remove the directory only once pg_ctl reports no
# server (3) or no cluster (4) there, and say so if both held.
STOP = "pg_ctl -D " + DIR + " stop -m immediate >/dev/null 2>&1; " +
       "pg_ctl -D " + DIR + " status >/dev/null 2>&1; s=$?; " +
       "if [ $s -eq 3 ] || [ $s -eq 4 ]; then rm -rf " + DIR + " 2>/dev/null && echo xq-stopped; fi"
XqShell.sp_net_shell_capture(STOP, 16)
# "xq-started", or the last lines from whichever step failed
up = XqShell.sp_net_shell_capture(
  "if ! out=$(initdb -D " + DIR + " -U spinel_test --auth=trust -E UTF8 --locale=C -N 2>&1); then echo \"$out\" | tail -5; " +
  "elif pg_ctl -D " + DIR + " -o '-p 16452 -c listen_addresses=127.0.0.1 -c unix_socket_directories=" + DIR + "'" +
  " -l " + DIR + "/log -w start >/dev/null 2>&1; then echo xq-started; else tail -5 " + DIR + "/log; fi", 4096)
if !up.to_s.include?("xq-started")
  XqShell.sp_net_shell_capture(STOP, 16)
  raise "live: postgres did not start on 16452\n" + up.to_s
end

begin
  c = xq_connect_retry(16452, "postgres", "spinel_test", "")
  puts "connected    " + (c.ready? && c.transaction_status == PG::PQTRANS_IDLE).to_s

  # Type metadata is independent of aliases, NULLs and the number of rows.
  r = c.exec("SELECT 7::bigint AS n, false AS flag, NULL::text AS note, '7'::varchar AS label")
  puts "simple_types " + [r.ftype(0), r.ftype(1), r.ftype(2), r.ftype(3)].join(",")
  puts "null_type    " + (r.getvalue(0, 2).nil? && r.ftype(2) == 25).to_s
  r = c.exec("SELECT 7::bigint AS n, false AS flag WHERE false")
  puts "empty_types  " + (r.ntuples == 0 && r.ftype(0) == 20 && r.ftype(1) == 16).to_s
  bounds = true
  [-1, 2].each do |index|
    raised = false
    begin
      r.ftype(index)
    rescue ArgumentError => e
      raised = e.message == "invalid field number " + index.to_s
    end
    bounds = bounds && raised
  end
  puts "type_bounds  " + bounds.to_s

  # The final command owns the result, even without a RowDescription (#8).
  r = c.exec("BEGIN; SELECT false; COMMIT")
  puts "batch_commit " + r.cmd_tag + " fields=" + r.nfields.to_s + " rows=" + r.ntuples.to_s
  puts "commit_empty " + (xq_no_type(r) && r.getvalue(0, 0).nil?).to_s
  c.exec("CREATE TEMP TABLE widgets (flag boolean)")
  r = c.exec("SELECT false; UPDATE widgets SET flag = true WHERE false")
  puts "batch_update " + r.cmd_tag + " fields=" + r.nfields.to_s + " rows=" + r.ntuples.to_s
  puts "update_empty " + (xq_no_type(r) && r.getvalue(0, 0).nil?).to_s
  r = c.exec("SELECT false; SELECT 7::bigint AS last WHERE false")
  puts "batch_zero   " + (r.cmd_tag == "SELECT 0" && r.ntuples == 0 && r.nfields == 1 && r.fields[0] == "last" && r.ftype(0) == 20).to_s
  r = c.exec("")
  puts "simple_empty " + (r.cmd_tag == "" && r.nfields == 0 && r.ntuples == 0 && xq_no_type(r)).to_s
  raised = false
  begin
    c.exec("SELECT false; SELECT 1 / 0")
  rescue => e
    raised = e.message.include?("division by zero")
  end
  puts "batch_error  " + (raised && c.transaction_status == PG::PQTRANS_IDLE).to_s
  r = c.exec("SELECT false")
  puts "batch_resume " + (r.getvalue(0, 0) == "f" && r.ftype(0) == 16).to_s

  # A self-notification is delivered between the final CommandComplete and
  # ReadyForQuery. Notifications remain unexposed, but must not erase data.
  c.exec("LISTEN result_boundary")
  r = c.exec("NOTIFY result_boundary, 'hello'; SELECT false AS flag")
  puts "notify_result " + (r.cmd_tag == "SELECT 1" && r.nfields == 1 && r.ntuples == 1 &&
                            r.fields[0] == "flag" && r.getvalue(0, 0) == "f" && r.ftype(0) == 16).to_s
  c.exec("UNLISTEN result_boundary")

  # --- parameters travel apart from the SQL ---------------------------------------

  r = c.exec_params("SELECT $1::text AS a, $2::text AS b, $3::text AS c, $4::text AS d",
                    ["hello", nil, "", "it's \"quoted\"; DROP TABLE x; --"])
  puts "fields       " + r.fields.join(",")
  puts "bound_types  " + [r.ftype(0), r.ftype(1), r.ftype(2), r.ftype(3)].join(",")
  puts "param_text   " + r.getvalue(0, 0).to_s
  b = r.getvalue(0, 1)
  puts "param_null   " + b.nil?.to_s
  e3 = r.getvalue(0, 2)
  puts "param_empty  " + (!e3.nil? && e3 == "").to_s
  puts "param_quotes " + r.getvalue(0, 3).to_s

  r = c.exec_params("SELECT $1::int + 1", [41])
  puts "param_int    " + r.getvalue(0, 0).to_s

  # 100 KB each way: more than one read_some(65536)
  big = "x" * 100000
  r = c.exec_params("SELECT length($1::text), $1::text AS v", [big])
  v = r.getvalue(0, 1).to_s
  puts "param_large  " + r.getvalue(0, 0).to_s + " " + (v == big).to_s

  # the server counts characters, so it decoded the bytes as UTF-8
  u = "héllo→wörld"
  r = c.exec_params("SELECT length($1::text), $1::text AS v", [u])
  v = r.getvalue(0, 1).to_s
  puts "param_utf8   " + r.getvalue(0, 0).to_s + " " + (v.b == u.b).to_s

  # --- a named statement, prepared once and reused --------------------------------

  c.exec("CREATE TABLE items (id serial PRIMARY KEY, name text UNIQUE, note text)")
  r = c.prepare("ins", "INSERT INTO items (name, note) VALUES ($1, $2) RETURNING id")
  puts "prepare      " + (r.ntuples == 0 && r.nfields == 0).to_s
  r = c.exec_prepared("ins", ["alice", "first"])
  puts "prep_run1    " + r.cmd_tag + " id=" + r.getvalue(0, 0).to_s
  puts "prep_type    " + r.ftype(0).to_s
  r = c.exec_prepared("ins", ["bob", nil])
  puts "prep_run2    " + r.cmd_tag + " id=" + r.getvalue(0, 0).to_s
  r = c.exec("SELECT count(*) FROM pg_prepared_statements WHERE name = 'ins'")
  puts "prep_server  " + r.getvalue(0, 0).to_s

  r = c.exec_params("INSERT INTO items (name) VALUES ($1)", ["carol"])
  puts "insert_tag   " + r.cmd_tag + " fields=" + r.nfields.to_s

  # --- errors drain to ReadyForQuery; the connection carries on -------------------

  raised = false
  begin
    c.exec_prepared("ins", ["alice", "again"])
  rescue => e
    raised = e.message.include?("duplicate key")
  end
  puts "err_unique   " + raised.to_s
  r = c.exec_prepared("ins", ["dave", nil])
  puts "err_recovers " + r.cmd_tag

  raised = false
  begin
    c.exec_params("SELEC $1", ["x"])
  rescue => e
    raised = e.message.include?("syntax error")
  end
  puts "err_parse    " + raised.to_s

  raised = false
  begin
    c.exec_prepared("ins", ["only-one"])
  rescue => e
    raised = e.message.include?("bind message supplies 1 parameters")
  end
  puts "err_bind     " + raised.to_s

  c.close_prepared("ins")
  raised = false
  begin
    c.exec_prepared("ins", ["erin", nil])
  rescue => e
    raised = e.message.include?("does not exist")
  end
  puts "closed_stmt  " + raised.to_s
  r = c.exec("SELECT count(*) FROM pg_prepared_statements")
  puts "prep_freed   " + r.getvalue(0, 0).to_s
  r = c.exec_params("SELECT count(*) FROM items", [])
  puts "after_errors " + r.getvalue(0, 0).to_s

  # --- transaction status -----------------------------------------------------------

  c.exec_params("BEGIN", [])
  puts "tx_begin     " + (c.transaction_status == PG::PQTRANS_INTRANS).to_s
  c.exec_params("INSERT INTO items (name) VALUES ($1)", ["frank"])
  raised = false
  begin
    c.exec_params("INSERT INTO items (name) VALUES ($1)", ["frank"])
  rescue => e
    raised = e.message.include?("duplicate key")
  end
  puts "tx_error     " + (raised && c.transaction_status == PG::PQTRANS_INERROR).to_s
  raised = false
  begin
    c.exec_params("SELECT 1", [])
  rescue => e
    raised = e.message.include?("current transaction is aborted")
  end
  puts "tx_aborted   " + (raised && c.transaction_status == PG::PQTRANS_INERROR).to_s
  c.exec("ROLLBACK")
  puts "tx_rollback  " + (c.transaction_status == PG::PQTRANS_IDLE).to_s
  r = c.exec_params("SELECT count(*) FROM items WHERE name = $1", ["frank"])
  puts "tx_undone    " + r.getvalue(0, 0).to_s
  c.exec("BEGIN")
  c.exec_params("UPDATE items SET note = $1 WHERE name = $2", ["seen", "bob"])
  c.exec_params("COMMIT", [])
  puts "tx_commit    " + (c.transaction_status == PG::PQTRANS_IDLE).to_s
  r = c.exec_params("SELECT note FROM items WHERE name = $1", ["bob"])
  puts "tx_kept      " + r.getvalue(0, 0).to_s

  # --- other types arrive as text -------------------------------------------------

  r = c.exec_params("SELECT $1::uuid, $2::jsonb, $3::text[], $4::boolean, $5::numeric * 2",
                    ["123e4567-e89b-12d3-a456-426614174000", "{\"b\": 1, \"a\": [true, null]}",
                     "{x,\"y z\",NULL}", "t", "1.25"])
  puts "type_uuid    " + r.getvalue(0, 0).to_s
  puts "type_jsonb   " + r.getvalue(0, 1).to_s
  puts "type_array   " + r.getvalue(0, 2).to_s
  puts "type_bool    " + r.getvalue(0, 3).to_s
  puts "type_numeric " + r.getvalue(0, 4).to_s

  # --- no rows, an empty query, many rows -----------------------------------------

  r = c.exec_params("SELECT $1::text AS v WHERE false", ["x"])
  puts "no_rows      " + r.fields.join(",") + " " + r.ntuples.to_s + " " + r.cmd_tag
  puts "no_rows_type " + r.ftype(0).to_s
  c.prepare("empty_typed", "SELECT $1::boolean AS flag WHERE false")
  first = c.exec_prepared("empty_typed", ["false"])
  second = c.exec_prepared("empty_typed", ["true"])
  c.close_prepared("empty_typed")
  puts "prep_empty   " + (first.ntuples == 0 && second.ntuples == 0 && first.ftype(0) == 16 && second.ftype(0) == 16).to_s
  r = c.exec_params("", [])
  puts "empty_query  " + (r.nfields == 0 && r.ntuples == 0 && r.cmd_tag == "").to_s
  r = c.exec_params("SELECT g, 'row ' || g FROM generate_series(1, $1::int) AS g ORDER BY g", ["20000"])
  puts "many_rows    " + r.ntuples.to_s + " " + r.getvalue(19999, 1).to_s + " " + r.cmd_tag

  c.close
ensure
  # a failed teardown shows in the snapshot, without hiding an exception
  down = XqShell.sp_net_shell_capture(STOP, 16)
  if !down.to_s.include?("xq-stopped")
    puts "teardown     failed; check " + DIR
  end
end
puts "done"
