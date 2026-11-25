# frozen_string_literal: true

module Nightshift
  # Warm handoff between worker sessions. Every attempt is a fresh agent session with an empty
  # context; these notes carry over what the next session needs from the ones before it:
  #
  #   - for a retry (or an escalation): what each earlier attempt of the task changed (files and
  #     the definitions it wrote) and its last answer, so the next one does not repeat it blindly;
  #   - for later tasks: the definitions each kept task added, with their signatures, so the
  #     worker reuses them instead of rediscovering or duplicating them.
  #
  # Only what the harness saw goes in: the attempt's own diff and its last DONE/STUCK line. Never
  # test or holdout content. Pure functions; Night records, Briefing renders.
  module Handover
    MAX_DEFS = 8     # definitions recorded per discarded attempt
    MAX_TRIED = 4    # earlier attempts summarised in a retry prompt
    MAX_ADDED = 12   # definitions recorded per kept task
    MAX_BUILT = 40   # definition lines from earlier tasks in a prompt

    # A line that starts a definition, in the languages a night is likely to touch: def (Ruby,
    # Python), function/class (JS/TS), fn (Rust), func (Go), plus exported constants and arrow
    # functions assigned to a name.
    DEFINITION = Regexp.union(
      /\A(?:export\s+(?:default\s+)?)?(?:pub(?:\([\w ]+\))?\s+)?(?:async\s+)?
         (?:def|function\*?|class|module|fn|interface|type|struct|enum|trait)\s+[\w.$:]+/x,
      /\Afunc\s+(?:\([^)]*\)\s*)?\w+/,
      /\A(?:export\s+)?(?:const|let|var)\s+[\w$]+\s*=\s*(?:async\s*)?(?:\([^)]*\)\s*=>|[\w$]+\s*=>|function\b)/,
      /\Aexport\s+(?:const|let|var)\s+[\w$]+/
    )
    ARROW_OR_FUNCTION = /\A\s*(?:async\b|\(|function\b|[\w$]+\s*=>)/

    module_function

    # "path: signature" for each definition a patch adds, outside test files, in patch order.
    def definitions(patch, test_paths: [])
      Gates.each_added_line(patch).filter_map do |file, line|
        next if Gates.test_path?(file, test_paths)

        code = line[1..].strip
        "#{file}: #{signature(code)}" if DEFINITION.match?(code)
      end.uniq
    end

    # The head of a definition line: no body, no trailing "{" or ":", and for a plain constant
    # only its name ("export const LORDS", not the whole array).
    def signature(code)
      if code.match?(/\A(?:export\s+)?(?:const|let|var)\s/)
        name, value = code.split("=", 2)
        code = name.strip unless value.nil? || value.match?(ARROW_OR_FUNCTION)
      end
      code.sub(/\s*(?:=>)?\s*[{:]?\s*\z/, "")[0, 120]
    end

    # What one discarded attempt did, as stored in state.json (task state "tried").
    def attempt_record(number:, adapter:, why:, changed:, patch:, said:, test_paths: [])
      { "attempt" => number, "adapter" => adapter, "why" => why.sub(/\Ayou\b/, "it"), "files" => changed.first(10),
        "defs" => definitions(patch, test_paths: test_paths).first(MAX_DEFS), "said" => said.to_s.strip[0, 300] }
    end

    # One earlier attempt in a line of its own, then what it did.
    def describe(rec) = "Attempt #{rec['attempt']} (#{rec['adapter']}): #{rec['why']}.\n#{what_it_did(rec)}"

    # Markdown bullets for an attempt record: what it changed, the definitions it wrote, its
    # last answer.
    def what_it_did(rec)
      files = Array(rec["files"])
      lines = [files.empty? ? "- It changed no files." : "- It changed: #{files.map { |f| "`#{f}`" }.join(', ')}"]
      defs = Array(rec["defs"])
      lines << "- Definitions it wrote (discarded with it):\n#{defs.map { |d| "  - `#{d}`" }.join("\n")}" if defs.any?
      lines << "- Its last answer: \"#{rec['said']}\"" unless rec["said"].to_s.empty?
      lines.join("\n")
    end

    # The "Previous attempts" section: short summaries of the earlier attempts, then the full
    # failure note of the latest one (gate output, path mistakes, what it tried).
    def previous_attempts(tried, latest_note)
      return "(first attempt)" if latest_note.to_s.empty?

      earlier = Array(tried)[0...-1].last(MAX_TRIED)
      parts = earlier.map { |rec| describe(rec) }
      parts.unshift("Earlier attempts, all discarded:") if parts.any?
      parts << "Latest attempt:" if parts.any?
      (parts << latest_note.to_s.chomp).join("\n\n")
    end

    # The "Already in the repo" section: definitions added by kept tasks, oldest first, as
    # [task id, [definition, ...]] pairs.
    def built(kept)
      lines = kept.flat_map { |id, defs| Array(defs).map { |d| "- `#{d}` (#{id})" } }
      lines.empty? ? "(nothing yet)" : lines.last(MAX_BUILT).join("\n")
    end
  end
end
