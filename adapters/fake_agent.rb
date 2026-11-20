# frozen_string_literal: true

# Deterministic stand-in for a coding agent, used by the self-test and for dry runs.
#
# Usage: ruby fake_agent.rb <prompt_file>      (runs in the repo; cwd is the working directory)
#
# It reads the prompt and runs every directive line, in order. The harness passes task notes
# into the prompt, so a task's notes decide what the fake agent does:
#
#   FAKE: write <path> <<<content>>>       write a file (\n in content becomes a newline)
#   FAKE: append <path> <<<content>>>      append to a file
#   FAKE: write@<n> <path> <<<content>>>   any op with @n runs only on attempt n
#   FAKE: tamper <path>                    edit a protected file (must be rejected)
#   FAKE: skip <path>                      add a minitest `skip` line to a test (must be rejected)
#   FAKE: sleep <seconds>                  simulate a hang (the harness must time out)
#   FAKE: commit                           commit by itself (the harness must fold it back)
#   FAKE: say <text>                       print a line (e.g. a false "DONE all tests pass")
#   FAKE: guardlog <<<json>>>              append an event to guard.jsonl next to the prompt,
#                                          as the pi guard extension would
#
# The attempt number is 1 + the number in "Attempt N failed" (the harness's failure note).

require "fileutils"

DIRECTIVE = /^\s*FAKE:\s*(\w+)(?:@(\d+))?\s*(.*)$/
CONTENT = /\A(\S+)\s*<<<(.*)>>>\s*\z/

prompt_file = ARGV.fetch(0)
prompt = File.read(prompt_file, encoding: "UTF-8")
attempt = (prompt[/Attempt (\d+) failed/, 1] || 0).to_i + 1

prompt.each_line(chomp: true) do |line|
  match = DIRECTIVE.match(line) or next
  op, only, rest = match.captures
  next if only && only.to_i != attempt

  case op
  when "write", "append"
    parts = CONTENT.match(rest) or next
    path, text = parts.captures
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, op == "write" ? "w" : "a", encoding: "UTF-8") { |f| f.write(text.gsub("\\n", "\n")) }
  when "tamper"
    File.open(rest.strip, "a") { |f| f.write("\n// tampered\n") }
  when "skip"
    File.open(rest.strip, "a") { |f| f.write("\nskip \"not now\"\n") }
  when "sleep"
    sleep Float(rest)
  when "commit"
    system("git", "add", "-A")
    system("git", "-c", "user.name=fake", "-c", "user.email=f@x", "commit", "-qm", "fake")
  when "guardlog"
    json = rest[/<<<(.*)>>>/, 1] or next
    File.open(File.join(File.dirname(prompt_file), "guard.jsonl"), "a") { |f| f.puts(json) }
  when "say"
    puts rest
  end
end

puts "DONE fake attempt #{attempt}"
