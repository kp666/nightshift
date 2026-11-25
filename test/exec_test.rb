# frozen_string_literal: true

require "test_helper"

# Finding programs on PATH before spawning them.
class ExecTest < Minitest::Test
  Exec = Nightshift::Exec
  ALIASES = File.join(ENV.fetch("LOCALAPPDATA", "-"), "Microsoft", "WindowsApps")

  def test_a_missing_program_is_not_found
    assert_raises(Exec::NotFound) { Exec.resolve("ns-no-such-program-#{Process.pid}") }
  end

  # pwsh installed from the Store is an App Execution Alias: a reparse point that File.file?
  # rejects, though spawning it works. A night whose server start_cmd was pwsh used to crash here.
  def test_an_app_execution_alias_is_found
    found = app_alias
    skip "no App Execution Alias on this machine" unless found

    with_path(ALIASES) { assert_equal File.join(ALIASES, found), Exec.resolve(File.basename(found, ".exe")) }
  end

  private

  def app_alias
    return unless Nightshift::WINDOWS && File.directory?(ALIASES)

    Dir.children(ALIASES).find { |name| name.end_with?(".exe") && !File.file?(File.join(ALIASES, name)) }
  end

  def with_path(dir)
    old = ENV.fetch("PATH", "")
    ENV["PATH"] = [dir, old].join(File::PATH_SEPARATOR)
    yield
  ensure
    ENV["PATH"] = old
  end
end
