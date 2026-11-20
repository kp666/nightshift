# frozen_string_literal: true

require "test_helper"

# Unit tests for the pure functions: path matching, the integrity and stray-path gates, the
# hard-code scan, plan validation and failure fingerprints.
class GatesTest < Minitest::Test
  Gates = Nightshift::Gates
  Plan = Nightshift::Plan

  GATES_CFG = { "protect" => ["tests/acceptance/", "tsconfig*.json"], "test_paths" => ["tests/"] }.freeze

  def test_matches_folders_and_globs
    assert Gates.matches?("tests/acceptance/a.rb", ["tests/acceptance/"])
    assert Gates.matches?("tsconfig.app.json", ["tsconfig*.json"])
    assert Gates.matches?("a/b/c.ts", ["*.ts"]), "* crosses folders"
    refute Gates.matches?("src/tests/acceptance/a.rb", ["tests/acceptance/"])
  end

  def test_test_path_detection
    assert Gates.test_path?("lib/foo_test.rb", [])
    assert Gates.test_path?("src/a.spec.ts", [])
    assert Gates.test_path?("spec/x.rb", [])
    refute Gates.test_path?("src/calc.rb", [])
  end

  def test_integrity_rejects_protected_edit_and_test_deletion
    edit = Gates.integrity([%w[M tests/acceptance/a.rb]], "", GATES_CFG, [])

    assert_equal "integrity", edit.gate
    refute_predicate edit, :ok?
    deleted = Gates.integrity([%w[D tests/unit/x_test.rb]], "", GATES_CFG, [])

    assert_match(/Deleted test files/, deleted.detail)
    assert_predicate Gates.integrity([%w[M src/calc.rb]], "", GATES_CFG, []), :ok?
  end

  def test_integrity_rejects_skip_markers
    patch = "+++ b/tests/unit/x_test.rb\n+skip \"later\"\n"

    refute_predicate Gates.integrity([%w[M tests/unit/x_test.rb]], patch, GATES_CFG, []), :ok?
    patch = "+++ b/tests/unit/a.test.ts\n+  it.only('x', () => {})\n"

    refute_predicate Gates.integrity([%w[M tests/unit/a.test.ts]], patch, GATES_CFG, []), :ok?
    patch = "+++ b/src/skip.rb\n+skip \"not a test\"\n"

    assert_predicate Gates.integrity([%w[M src/skip.rb]], patch, GATES_CFG, []), :ok?, "markers only count in tests"
  end

  def test_stray_paths
    tracked = %w[src/calc.rb src/lib/a.ts README.md]
    bad = Gates.stray_paths([["A", "toy/src/lib/b.ts"]], tracked, [], ["toy"])

    refute_predicate bad, :ok?
    assert_includes bad.detail, "did you mean 'src/lib/b.ts'"
    refute_predicate Gates.stray_paths([["A", " src/x.rb"]], tracked, [], []), :ok?, "leading space is garbled"
    assert_predicate Gates.stray_paths([["A", "src/new/x.rb"]], tracked, [], []), :ok?,
                     "new folder under a known top level"
    assert_predicate Gates.stray_paths([["A", "bench/x.rb"]], tracked, ["bench/"], []), :ok?, "allowed new folder"
    assert_predicate Gates.stray_paths([["A", "NOTES.md"]], tracked, [], []), :ok?, "new top-level file"
  end

  def test_hardcode_scan_flags_literals_copied_from_tests
    patch = "+++ b/src/sun.ts\n+return 23.4392911;\n+const s = \"expected output here\";\n"
    flags = Gates.hardcode_scan(patch, ["expect(x).toBe(23.4392911); 'expected output here'"], ["tests/"])

    assert_equal 2, flags.size
    assert_empty Gates.hardcode_scan(patch, ["nothing in common"], ["tests/"])
  end

  def test_plan_problems
    tasks = [
      { "id" => "A", "checks" => ["x"] },
      { "id" => "A", "checks" => ["x"] },
      { "id" => "B", "dependsOn" => ["C"] },
      { "id" => "X", "checks" => ["x"], "dependsOn" => ["Y"] },
      { "id" => "Y", "checks" => ["x"], "dependsOn" => ["X"] }
    ]
    problems = Plan.problems(tasks).join("\n")

    assert_includes problems, "duplicate id A"
    assert_includes problems, "B: needs at least one check"
    assert_includes problems, "B: depends on unknown task C"
    assert_includes problems, "dependency cycle"
    assert_empty Plan.problems([{ "id" => "A", "checks" => ["x"] }])
  end

  def test_fingerprint_ignores_timings_and_hashes
    a = Nightshift::Night.fingerprint("failed after 1.25s at commit 3f9a2c1d\n  in  foo")
    b = Nightshift::Night.fingerprint("failed after 9s at commit 77aa00bb in foo")

    assert_equal a, b
    refute_equal a, Nightshift::Night.fingerprint("failed in bar")
  end

  def test_deadline
    start = Time.new(2026, 11, 19, 23, 0, 0)

    assert_equal Time.new(2026, 11, 20, 7, 0, 0), Nightshift::Night.deadline({ "until" => "07:00" }, start)
    assert_equal Time.new(2026, 11, 19, 23, 30, 0), Nightshift::Night.deadline({ "until" => "" }, start, "23:30")
    assert_equal start + 7200, Nightshift::Night.deadline({ "until" => "", "hours" => 2 }, start)
    assert_nil Nightshift::Night.deadline({ "until" => "", "hours" => 0 }, start), "no limit by default"
    assert_nil Nightshift::Night.deadline({ "until" => "" }, start)
  end

  def test_clock_from_unquoted_yaml
    assert_equal "07:00", Nightshift::Project.clock(YAML.safe_load("t: 07:00")["t"])
    assert_equal "23:30", Nightshift::Project.clock("23:30")
  end

  def test_render_placeholders
    vars = { "repo" => "/r", "n" => 3 }

    assert_equal ["/r/x", "3", "{unknown}"], Nightshift::Adapters.render(["{repo}/x", "{n}", "{unknown}"], vars)
    assert_equal({ "K" => "/r" }, Nightshift::Adapters.render({ "K" => "{repo}" }, vars))
  end
end
