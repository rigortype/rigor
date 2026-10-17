# frozen_string_literal: true

# Self-check gate for #1956 / #1959: a directory joined into a `Dir.glob` pattern is read as glob syntax, so a
# project at `ds [x]` analysed nothing and a directory named `{..,zz}` walked its parent. The engine globs under a
# directory with `Rigor::RootedGlob.glob(root, pattern)` and a bundled plugin with
# `Dir.glob(pattern, base: root)` (a pattern without a leading `/`).
#
# A lexical check of the joined spellings, not a proof: it reads each non-comment line of `lib/` and
# `plugins/*/lib` for a `Dir.glob` / `Dir[]` / `Pathname.glob` whose argument starts with `File.join(` or a
# `<path>.join(` call or an interpolation (`"#{root}/…"`), and does not see a pattern built into a variable first.

require "spec_helper"

JOINED_ROOT_GLOB = /\b(?:Dir\.glob\(|Dir\[|Pathname\.glob\()\s*(?:File\.join\(|[\w@.]+\.join\(|"#\{)/

RSpec.describe "globbing under a directory (#1956, #1959)" do
  let(:sources) do
    root = File.expand_path("../..", __dir__)
    Dir.glob(["lib/**/*.rb", "plugins/*/lib/**/*.rb"], base: root).sort.to_h do |relative|
      [relative, File.readlines(File.join(root, relative))]
    end
  end

  it "joins no directory into a glob pattern" do
    # RootedGlob makes the one join, after escaping the root.
    offenders = sources.except("lib/rigor/rooted_glob.rb").flat_map do |relative, lines|
      lines.each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}" if !line.lstrip.start_with?("#") && line.match?(JOINED_ROOT_GLOB)
      end
    end

    expect(offenders).to be_empty
  end

  it "recognises the joined spellings (guard on the pattern itself)" do
    joined = ['Dir.glob(File.join(root, "**", "*.rb"))', 'Dir[File.join(DATA_ROOT, "*.yml")]',
              'Dir.glob(path.join("**", "*.rbs"))', "Dir.glob(\"\#{root}/**/*.rb\")",
              "Dir[\"\#{dir}/*.rb\"]"]

    expect(joined.grep(JOINED_ROOT_GLOB)).to eq(joined)
    expect(['Dir.glob("**/*.rb", base: root)'].grep(JOINED_ROOT_GLOB)).to be_empty
  end
end
