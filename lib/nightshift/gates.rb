# frozen_string_literal: true

module Nightshift
  # Verification gates. Everything here is deterministic and run by the harness, never by
  # the worker. Verifier#verify runs them in this order (cheapest and most tamper-relevant first):
  #
  #   1. integrity   protected paths untouched, no deleted tests, no new skip/only markers
  #   2. paths       no files created under a garbled or new top-level folder
  #   3. setup       optional commands (e.g. a build) that must succeed before checks
  #   4. task        the task's own acceptance checks
  #   5. holdout     hidden tests the worker never saw
  #   6. regression  checks (and holdouts) of every task already passed
  #   7. global      project-wide gates (typecheck, lint, full test suite)
  #
  # The hard-code scan is advisory: it never fails an attempt, it is listed in the report.
  module Gates
    # ok? false means the attempt is discarded; +gate+ names the gate that failed and
    # +detail+ is what the next attempt is told.
    Result = Data.define(:ok, :gate, :detail) do
      def initialize(ok:, gate: "", detail: "")
        super
      end

      def ok? = ok
    end

    PASS = Result.new(ok: true)

    SKIP_MARKERS = Regexp.union(
      /\b(it|test|describe|context|suite)\.(skip|only|todo)\b/, # JS test runners
      /\b(xit|xdescribe|xtest|xcontext|xspecify|fit|fdescribe)\s*\(/, # jasmine/rspec focus+skip
      /@pytest\.mark\.(skip|xfail)|pytest\.skip\(|@unittest\.skip/, # Python
      /#\[ignore\]|\bt\.Skip\(|\.skipIf\b/,                            # Rust, Go, vitest
      /^\+\s*(skip|pending)(\s*\(|\s+["']|\s*$)/                       # minitest / rspec
    )
    TEST_FILE = Regexp.union(
      %r{(^|/)(tests?|__tests__|spec)/}, /\.(test|spec)\.[a-z]+$/,
      %r{(^|/)test_[^/]+\.py$}, /_(test|spec)\.(py|go|rs|rb)$/
    )

    module_function

    def failed(gate, detail) = Result.new(ok: false, gate: gate, detail: detail)

    # Does +rel+ match any pattern? "dir/" matches everything below dir; other patterns are
    # globs where * also crosses folders, e.g. "tsconfig*.json".
    def matches?(rel, patterns)
      rel = Util.norm(rel)
      patterns.any? do |pattern|
        pattern = Util.norm(pattern)
        if pattern.end_with?("/")
          rel.start_with?(pattern)
        else
          rel == pattern || File.fnmatch?(pattern, rel, File::FNM_DOTMATCH)
        end
      end
    end

    def test_path?(rel, test_paths) = matches?(rel, test_paths) || TEST_FILE.match?(Util.norm(rel))

    def protected_hashes(repo, tracked, patterns)
      tracked.select { |rel| matches?(rel, patterns) && File.file?(File.join(repo, rel)) }
             .to_h { |rel| [rel, Util.sha256(File.join(repo, rel))] }
    end

    # Yields [file, added_line] for every added line in a unified diff.
    def each_added_line(patch)
      return enum_for(:each_added_line, patch) unless block_given?

      current = ""
      patch.each_line(chomp: true) do |line|
        if line.start_with?("+++ ")
          current = line.start_with?("+++ b/") ? line[6..] : ""
        elsif line.start_with?("+") && !current.empty?
          yield current, line
        end
      end
    end

    # 1. integrity
    # +holdout_paths+ are protected too: the hidden tests are in the repo only while the checks run.
    def integrity(status, patch, gates_cfg, holdout_paths)
      protect = gates_cfg["protect"] + holdout_paths
      tests = gates_cfg["test_paths"]
      edited = status.map(&:last).select { |path| matches?(path, protect) }
      return failed("integrity", "Edited read-only files: #{edited.first(20).join(', ')}") if edited.any?

      if gates_cfg.fetch("check_test_deletion", true)
        gone = status.select { |st, path| st.start_with?("D") && test_path?(path, tests) }.map(&:last)
        return failed("integrity", "Deleted test files: #{gone.first(20).join(', ')}") if gone.any?
      end
      if gates_cfg.fetch("check_skip_markers", true)
        hits = each_added_line(patch).select { |file, line| test_path?(file, tests) && SKIP_MARKERS.match?(line) }
                                     .map { |file, line| "#{file}: #{line[1..].strip[0, 120]}" }
        return failed("integrity", "Added skip/only markers to tests:\n#{hits.first(10).join("\n")}") if hits.any?
      end
      PASS
    end

    # 2. paths. Local models garble paths: "k My-app-x/src/lib/a.ts", "<project>/src/...",
    # " src/x.ts". Such a write creates a junk tree while the real file stays untouched.
    # Reject files added under a top-level folder that did not exist (and is not expected),
    # and point at the likely intended path.
    def stray_paths(status, tracked, allowed, project_names)
      tracked = tracked.map { |t| Util.norm(t) }
      tops = (tracked + allowed.reject(&:empty?).map { |a| Util.norm(a) }).to_set { |t| t.split("/").first }
      dirs = tracked.select { |t| t.include?("/") }.to_set { |t| File.dirname(t) }
      names = project_names.reject(&:empty?).to_set(&:downcase)
      bad = status.filter_map do |st, path|
        next unless st.start_with?("A")

        segs = Util.norm(path).split("/")
        garbled = segs[0...-1].any? { |seg| seg != seg.strip || names.include?(seg.downcase) }
        next unless (segs.size > 1 && !tops.include?(segs.first)) || garbled

        guess = (1...segs.size).map { |i| segs[i..].join("/") }
                               .find { |rest| rest.include?("/") && dirs.include?(File.dirname(rest)) }
        "'#{path}'#{" (did you mean '#{guess}'?)" if guess}"
      end
      return PASS if bad.empty?

      failed("paths", "Created files under a folder that does not exist in the project, which usually " \
                      "means a wrong path: #{bad.first(10).join(', ')}. All paths are relative to the repository " \
                      "root (your working directory); never prefix them with the project folder name.")
    end

    STRING_LITERAL = /(["'`])((?:(?!\1).){12,200})\1/
    NUMBER_LITERAL = /(?<![\w.])-?\d+\.\d{4,}(?![\w.])/

    # Advisory: literals added to non-test code that also appear verbatim in tests or holdouts.
    # Returning the expected value is the classic way to "pass"; for numeric code (astronomy)
    # high-precision constants copied from expected outputs are the tell-tale sign.
    def hardcode_scan(patch, reference_texts, test_paths)
      reference = reference_texts.join("\n")
      return [] if reference.empty?

      flags = each_added_line(patch).reject { |file, _| test_path?(file, test_paths) }.flat_map do |file, line|
        body = line[1..]
        strings = body.scan(STRING_LITERAL).map(&:last).select { |s| reference.include?(s) }
                      .map { |s| "#{file}: string literal also in tests: #{s[0, 60].inspect}" }
        numbers = body.scan(NUMBER_LITERAL).select { |n| reference.include?(n) }
                      .map { |n| "#{file}: numeric literal also in tests: #{n}" }
        strings + numbers
      end
      flags.uniq.sort.first(25)
    end

    # Copy hidden tests into the repo for the duration of verification only.
    def install_holdout(holdout_root, repo, rels)
      rels.map do |rel|
        src = File.join(holdout_root, rel)
        raise Error, "holdout file missing: #{src}" unless File.file?(src)

        dst = File.join(repo, rel)
        FileUtils.mkdir_p(File.dirname(dst))
        FileUtils.cp(src, dst)
        dst
      end
    end

    def remove_files(paths) = paths.each { |path| FileUtils.rm_f(path) }

    # Run commands in order; the first failure fails the gate with its output tail.
    def run_commands(gate, cmds, shell:, repo:, run_dir:, timeout_s:)
      cmds.each.with_index(1) do |cmd, i|
        out = File.join(run_dir, "#{gate}-#{i}.out")
        err = File.join(run_dir, "#{gate}-#{i}.err")
        r = Exec.run_shell(cmd, shell, cwd: repo, timeout_s: timeout_s, stdout: out, stderr: err)
        next if r.ok?

        why = r.timed_out? ? "timed out" : "exit #{r.rc}"
        return failed(gate, "$ #{cmd}\n(#{why})\n#{Util.tail(out)}\n#{Util.tail(err, 15, 1200)}".strip)
      end
      Result.new(ok: true, gate: gate)
    end
  end
end
