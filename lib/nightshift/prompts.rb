# frozen_string_literal: true

module Nightshift
  # Prompt templates (templates/prompts/*.md). A project can override any of them by putting a
  # file with the same name in <state>/prompts/. Placeholders look like {{NAME}}.
  module Prompts
    module_function

    def load(project, name)
      local = File.join(project.dir, "prompts", name)
      Util.read(File.file?(local) ? local : File.join(PROMPTS, name))
    end

    def render(template, vars)
      vars.reduce(template) { |text, (key, value)| text.gsub("{{#{key}}}") { value.to_s } }
    end

    def build(project, name, vars) = render(load(project, name), vars)
  end
end
