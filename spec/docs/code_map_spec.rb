# frozen_string_literal: true

# Gate docs/agents/code-map.md against the tree it maps (ADR-116, 2026-11-17 amendment).
#
# The map is what a planning agent reads to predict which files a change touches. It is only useful
# while it is complete and true, and a hand-kept map is neither for long: 135 files were added under
# lib/rigor/inference/ in the 60 days before it was written. So two things are mechanical:
#
#   - every directory and every top-level file of lib/rigor/ has a row, so a new namespace cannot
#     land unmapped;
#   - every repository path the map names exists, so a move or a rename has to update it.
#
# What a row says about its path is not checked here; review checks that.

require "spec_helper"

CODE_MAP_ROOT = File.expand_path("../..", __dir__)
CODE_MAP_PATH = File.join(CODE_MAP_ROOT, "docs/agents/code-map.md")

# A backticked repository path. Anything else in backticks (a constant, a method, a command) is not
# a path claim. `data/` and `schemas/` are named by a few rows; `lib/`, `spec/`, `sig/`, `docs/` by
# most.
CODE_MAP_NAMED_PATH = %r{`((?:lib|spec|sig|docs|data|schemas|bin)/[^`\s]*)`}

# The first cell of a table row, when it is one backticked path.
CODE_MAP_ROW_KEY = /^\| `([^`]+)` \|/

# The map is a lookup table, not a description of the engine. Today it is 169 lines; a map that needs
# far more than this is restating docs/internal-spec/.
CODE_MAP_LINE_MAX = 220

module CodeMapSpecSupport
  module_function

  def named_paths(text)
    text.scan(CODE_MAP_NAMED_PATH).flatten.uniq
  end

  def row_keys(text)
    text.each_line.filter_map { |line| line[CODE_MAP_ROW_KEY, 1] }
  end

  # Every directory and every top-level `.rb` file directly under `lib/rigor/` of `root`, spelled as
  # the map spells them: a directory with a trailing slash.
  def expected_keys(root)
    Dir.children(File.join(root, "lib/rigor")).sort.filter_map do |entry|
      full = File.join(root, "lib/rigor", entry)
      if File.directory?(full)
        "lib/rigor/#{entry}/"
      elsif entry.end_with?(".rb")
        "lib/rigor/#{entry}"
      end
    end
  end

  def unmapped(text, root)
    expected_keys(root) - row_keys(text)
  end

  def missing(text, root)
    named_paths(text).reject { |path| File.exist?(File.join(root, path)) }
  end

  # A row key for a directory must end in a slash and a file's must not, or `unmapped` would pass a
  # file row standing in for a directory of the same stem.
  def misspelled_keys(text, root)
    row_keys(text).select do |key|
      full = File.join(root, key)
      File.exist?(full) && File.directory?(full) != key.end_with?("/")
    end
  end
end

RSpec.describe "docs/agents/code-map.md" do
  let(:text) { File.read(CODE_MAP_PATH) }

  it "has a row for every directory and top-level file of lib/rigor/" do
    expect(CodeMapSpecSupport.unmapped(text, CODE_MAP_ROOT)).to eq([]), <<~MSG
      docs/agents/code-map.md has no row for these. Add one saying what the path is responsible
      for; a new namespace is what a planning agent most needs to find.
    MSG
  end

  it "names only paths that exist" do
    expect(CodeMapSpecSupport.missing(text, CODE_MAP_ROOT)).to eq([]), <<~MSG
      docs/agents/code-map.md names these paths, which do not exist. A move or rename updates the
      map in the same change.
    MSG
  end

  it "spells a directory with a trailing slash and a file without one" do
    expect(CodeMapSpecSupport.misspelled_keys(text, CODE_MAP_ROOT)).to eq([])
  end

  it "stays a lookup table" do
    expect(text.lines.size).to be <= CODE_MAP_LINE_MAX
  end

  it "is reachable from AGENTS.md" do
    expect(File.read(File.join(CODE_MAP_ROOT, "AGENTS.md"))).to include("docs/agents/code-map.md")
  end

  # The checks above read the real tree, where they pass. These run them against trees and texts
  # built to fail, so a check that stopped looking would not stay green.
  describe "the checks themselves" do
    let(:root) do
      Dir.mktmpdir.tap do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib/rigor/type"))
        File.write(File.join(dir, "lib/rigor/type.rb"), "")
        File.write(File.join(dir, "lib/rigor/type/union.rb"), "")
        File.write(File.join(dir, "lib/rigor/notes.txt"), "")
      end
    end
    let(:complete) do
      <<~MAP
        | Path | Responsible for |
        | --- | --- |
        | `lib/rigor/type/` | Types, built by `Combinator`. Start at `lib/rigor/type/union.rb`. |
        | `lib/rigor/type.rb` | Loads them. |
      MAP
    end

    after { FileUtils.remove_entry(root) }

    it "accepts a complete map and ignores non-Ruby files and non-path backticks" do
      expect(CodeMapSpecSupport.unmapped(complete, root)).to eq([])
      expect(CodeMapSpecSupport.missing(complete, root)).to eq([])
      expect(CodeMapSpecSupport.misspelled_keys(complete, root)).to eq([])
    end

    it "reports a directory with no row" do
      text = complete.lines.reject { |line| line.start_with?("| `lib/rigor/type/`") }.join
      expect(CodeMapSpecSupport.unmapped(text, root)).to eq(["lib/rigor/type/"])
    end

    it "reports a top-level file with no row" do
      text = complete.lines.reject { |line| line.start_with?("| `lib/rigor/type.rb`") }.join
      expect(CodeMapSpecSupport.unmapped(text, root)).to eq(["lib/rigor/type.rb"])
    end

    it "does not take a mention in another row's prose for a row" do
      text = <<~MAP
        | `lib/rigor/type.rb` | Loads `lib/rigor/type/`. |
      MAP
      expect(CodeMapSpecSupport.unmapped(text, root)).to eq(["lib/rigor/type/"])
    end

    it "reports a named path that does not exist, in a row key or in prose" do
      text = "#{complete}| `lib/rigor/gone/` | See `spec/rigor/gone_spec.rb`. |\n"
      expect(CodeMapSpecSupport.missing(text, root)).to eq(["lib/rigor/gone/", "spec/rigor/gone_spec.rb"])
    end

    it "reports a directory row spelled without its slash" do
      text = complete.sub("`lib/rigor/type/` |", "`lib/rigor/type` |")
      expect(CodeMapSpecSupport.misspelled_keys(text, root)).to eq(["lib/rigor/type"])
      expect(CodeMapSpecSupport.unmapped(text, root)).to eq(["lib/rigor/type/"])
    end
  end
end
