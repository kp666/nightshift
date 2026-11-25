# frozen_string_literal: true

require_relative "test_helper"

# lib/ARCHITECTURE.md is the map of the code. It must name every file under lib/, and every .rb
# file it names must exist, so it cannot go stale when files are added, renamed or removed.
class DocsTest < Minitest::Test
  MAP = File.join(Nightshift::HOME, "lib", "ARCHITECTURE.md")

  def map = File.read(MAP, encoding: "UTF-8")
  def ruby_files(dirs) = Dir.glob("{#{dirs}}/**/*.rb", base: Nightshift::HOME).map { |path| File.basename(path) }

  def test_the_architecture_map_names_every_lib_file
    missing = ruby_files("lib").reject { |name| map.include?("`#{name}`") }

    assert_empty missing, "describe these files in lib/ARCHITECTURE.md"
  end

  def test_the_architecture_map_names_only_files_that_exist
    stale = map.scan(/`([a-z_]+\.rb)`/).flatten.uniq - ruby_files("lib,bin,adapters,test")

    assert_empty stale, "lib/ARCHITECTURE.md names files that no longer exist"
  end
end
