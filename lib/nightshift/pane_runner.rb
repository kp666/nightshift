# frozen_string_literal: true

# Runs inside a tmux pane (see Pane): starts one agent on the pane's terminal, so you watch its
# own screen live, and reports back to the harness through files. Standalone on purpose: no gems
# and no nightshift code, so it starts fast and quoting never matters (every value comes from
# a JSON spec, not from a command line).
#
#   ruby pane_runner.rb SPEC.json
#
# SPEC: argv (argv[0] already resolved to a full path), cwd, env, pid_file, rc_file, linger_s.
# pid_file gets the agent's process id as soon as it starts (the harness kills its process tree
# on timeout); rc_file gets its exit code when it ends, written atomically. The pane then stays
# open for linger_s seconds so the last screen can still be read; the harness closes it when
# the next attempt starts.
require "json"

spec = JSON.parse(File.read(ARGV.fetch(0)))
argv = spec.fetch("argv")
rc_file = spec.fetch("rc_file")

write = lambda do |path, text|
  File.write("#{path}.tmp", text)
  File.rename("#{path}.tmp", path)
end

rc =
  begin
    pid = Process.spawn(spec.fetch("env", {}), [argv.first, argv.first], *argv.drop(1), chdir: spec.fetch("cwd"))
    write.call(spec.fetch("pid_file"), "#{pid}\n")
    Process.wait(pid)
    $?.exitstatus || 1 # rubocop:disable Style/SpecialGlobalVars
  rescue SystemCallError => e
    warn "nightshift: could not start #{argv.first}: #{e.message}"
    127
  end
write.call(rc_file, "#{rc}\n")

linger = Integer(spec.fetch("linger_s", 0))
if linger.positive?
  puts "\n[nightshift] the agent exited with code #{rc}. This pane closes when the next attempt starts."
  sleep linger
end
