# frozen_string_literal: true

require "test_helper"

# Unit tests for the warm handoff: which definitions a diff adds, the attempt record, and the
# prompt sections built from them.
class HandoverTest < Minitest::Test
  Handover = Nightshift::Handover

  def patch(file, *lines)
    "diff --git a/#{file} b/#{file}\n--- a/#{file}\n+++ b/#{file}\n@@ -1 +1 @@\n" \
      "#{lines.map { |l| "+#{l}\n" }.join}"
  end

  def test_definitions_in_several_languages
    diff = patch("src/lib/time.ts",
                 "export function phaseAt(jd: number): number {", "  const x = 1;",
                 "export const toJd = (date: Date): number => {", "export const NAMES = ['a', 'b'];",
                 "export interface Phase {", "class Clock {") +
           patch("lib/calc.py", "def mean(xs):", "    return sum(xs)") +
           patch("lib/calc.rb", "  def self.mean(xs)", "module Calc") +
           patch("calc.go", "func (c *Calc) Mean(xs []float64) float64 {")

    assert_equal ["src/lib/time.ts: export function phaseAt(jd: number): number",
                  "src/lib/time.ts: export const toJd = (date: Date): number",
                  "src/lib/time.ts: export const NAMES",
                  "src/lib/time.ts: export interface Phase",
                  "src/lib/time.ts: class Clock",
                  "lib/calc.py: def mean(xs)",
                  "lib/calc.rb: def self.mean(xs)",
                  "lib/calc.rb: module Calc",
                  "calc.go: func (c *Calc) Mean(xs []float64) float64"], Handover.definitions(diff)
  end

  def test_test_files_and_removed_lines_are_skipped
    diff = [patch("tests/acceptance/a.test.ts", "function helper() {"),
            patch("spec/x.ts", "export function fixture() {"),
            "diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n-function old() {\n"].join

    assert_empty Handover.definitions(diff, test_paths: ["spec/"])
  end

  def test_attempt_record_and_previous_attempts
    first = Handover.attempt_record(number: 1, adapter: "pi-local", why: "you made no changes", changed: [],
                                    patch: "", said: "STUCK cannot find the file")
    second = Handover.attempt_record(number: 2, adapter: "pi-local", why: "the 'task' check failed",
                                     changed: ["src/a.ts"], patch: patch("src/a.ts", "function a() {"), said: "")
    text = Handover.previous_attempts([first, second], "Attempt 2 failed because the 'task' check failed.\n")

    assert_equal "it made no changes", first["why"]
    assert_includes text, "Attempt 1 (pi-local): it made no changes.\n- It changed no files."
    assert_includes text, "Its last answer: \"STUCK cannot find the file\""
    assert_match(/Latest attempt:\n\nAttempt 2 failed because the 'task' check failed\.\z/, text)
    refute_match(/Attempt 1 failed/, text, "older attempts must not look like a failure note")
  end

  def test_first_attempt_and_nothing_built
    assert_equal "(first attempt)", Handover.previous_attempts(nil, "")
    assert_equal "(nothing yet)", Handover.built([])
  end

  def test_built_lists_newest_last_within_the_cap
    kept = [["T01", ["a.rb: def a"]], ["T02", Array.new(Handover::MAX_BUILT) { |i| "b.rb: def b#{i}" }]]
    lines = Handover.built(kept).lines

    assert_equal Handover::MAX_BUILT, lines.size
    assert_equal "- `b.rb: def b#{Handover::MAX_BUILT - 1}` (T02)", lines.last
  end
end
