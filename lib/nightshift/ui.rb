# frozen_string_literal: true

module Nightshift
  # What the commands print: one line per step, marked passed or failed, plus headings, notes,
  # warnings and the next command to run. In a terminal the marks are coloured icons. When the
  # output goes to a file (night.log, the tests) they are plain words, so
  # logs stay greppable. NO_COLOR turns the icons and colours off too.
  #
  # Errors are not printed here: services raise Nightshift::Error and the CLI prints it.
  # The night loop's event lines (Night#log) are a log, not UI, and do not go through here.
  module UI
    module_function

    def step(ok, message)
      mark = if fancy?
               ok ? color("✔", :green) : color("✘", :red)
             else
               ok ? "ok  " : "FAIL"
             end
      say("  #{mark} #{message}")
    end

    def heading(text) = say(fancy? ? color(text, :bold) : text)
    def info(text) = say(text)
    def warning(text) = say(fancy? ? color("! #{text}", :yellow) : "warning: #{text}")
    def next_step(text) = say(fancy? ? color("→ next: #{text}", :cyan) : "Next: #{text}")

    def say(text) = $stdout.puts(text)
    def fancy? = $stdout.tty? && !ENV.key?("NO_COLOR")
    def color(text, *styles) = shell.set_color(text, *styles)
    def shell = @shell ||= Thor::Shell::Color.new
  end
end
