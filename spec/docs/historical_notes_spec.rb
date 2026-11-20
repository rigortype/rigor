# frozen_string_literal: true

# A note or design document whose content is spent carries a `> **Historical**` banner under its title, and
# the root `.ignore` lists it so a default `rg` (and the agent Grep tool built on it) skips it. The file
# stays where it is, so every link to it still resolves; `rg --no-ignore-dot <term> docs/` reads it.
# This spec keeps the two in step: a banner without its `.ignore` entry still shows up in every search,
# and an entry without a banner hides a live note with nothing on the page saying why.
# The rules are in docs/notes/README.md § "Historical notes".

require "spec_helper"

HISTORICAL_BANNER = /\A> \*\*Historical\*\* \(marked \d{4}-\d{2}-\d{2}\): \S/
HISTORICAL_IGNORE_BLOCK = /^# BEGIN historical\n(.*?)^# END historical$/m

RSpec.describe "historical notes and the root .ignore" do
  let(:root) { File.expand_path("../..", __dir__) }

  let(:bannered) do
    candidates = Dir.glob(["docs/notes/**/*.md", "docs/design/*.md"], base: root)
    candidates.select { |relative| File.foreach(File.join(root, relative)).first(5).grep(HISTORICAL_BANNER).any? }.sort
  end

  let(:ignored) do
    match = File.read(File.join(root, ".ignore")).match(HISTORICAL_IGNORE_BLOCK)
    raise "the root .ignore has no `# BEGIN historical` … `# END historical` block" unless match

    entries = match[1].lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
    entries.map { |line| line.delete_prefix("/") }
  end

  it "lists every bannered note in the .ignore block, and nothing else" do
    expect(ignored).to eq(ignored.sort.uniq)
    expect(ignored).to eq(bannered)
  end

  it "points every entry at a file that exists" do
    expect(ignored.reject { |relative| File.file?(File.join(root, relative)) }).to be_empty
  end

  it "recognises the banner spelling (guard on the pattern itself)" do
    samples = ["> **Historical** (marked 2026-11-20): the punch list landed.", "Status: historical",
               "> **Historical**: no date"]

    expect(samples.grep(HISTORICAL_BANNER)).to eq([samples.first])
  end
end
