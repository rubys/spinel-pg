# Structured errors on real PostgreSQL; a committed Spinel snapshot.
# Like the other live lanes, owns a throwaway UTF8/C-locale trust server.
require "pg"
require_relative "support/error_cases"

module ErrorShell
  ffi_func :sp_net_shell_capture, [:str, :int], :binstr
end

DIR = "/tmp/spinel-pg-live-errors"
STOP = "pg_ctl -D " + DIR + " stop -m immediate >/dev/null 2>&1; " +
       "pg_ctl -D " + DIR + " status >/dev/null 2>&1; s=$?; " +
       "if [ $s -eq 3 ] || [ $s -eq 4 ]; then rm -rf " + DIR + " 2>/dev/null && echo errors-stopped; fi"
ErrorShell.sp_net_shell_capture(STOP, 32)
up = ErrorShell.sp_net_shell_capture(
  "if ! out=$(initdb -D " + DIR + " -U spinel_test --auth=trust -E UTF8 --locale=C -N 2>&1); then echo \"$out\" | tail -5; " +
  "elif pg_ctl -D " + DIR + " -o '-p 16453 -c listen_addresses=127.0.0.1 -c unix_socket_directories=" + DIR + "'" +
  " -l " + DIR + "/log -w start >/dev/null 2>&1; then echo errors-started; else tail -5 " + DIR + "/log; fi", 4096)
if !up.to_s.include?("errors-started")
  ErrorShell.sp_net_shell_capture(STOP, 32)
  raise "live: postgres did not start on 16453\n" + up.to_s
end

begin
  client = PG.connect("127.0.0.1", 16453, "postgres", "spinel_test", "")
  run_live_errors(client, false)
  client.close
ensure
  down = ErrorShell.sp_net_shell_capture(STOP, 32)
  raise "live: teardown failed" unless down.to_s.include?("errors-stopped")
end
puts "done"
