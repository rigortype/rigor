# frozen_string_literal: true

# Gate ADR-74's `llms.txt` sync: the gem's offline doc index (`docs/llms.txt`) must name every packaged manual
# chapter. #938 found chapters 18 and 19 shipped in `docs/manual/` while the index — hand-authored, never
# regenerated — still ended at 17; the sync follow-up ADR-74 deferred was never built, so nothing caught it.
#
# This only gates the **manual** listing, matching ADR-74's own divergence: the handbook section already reads
# `rigor docs --list handbook` for its own catalogue rather than naming chapters by hand, so it cannot drift the
# same way. `docs/manual/README.md` is excluded from the glob — it is the chapter TOC, not a chapter.
require "spec_helper"

LLMS_TXT_DOCS_ROOT = File.expand_path("../../docs", __dir__)
LLMS_TXT_MANUAL_DIR = File.join(LLMS_TXT_DOCS_ROOT, "manual")
LLMS_TXT_PATH = File.join(LLMS_TXT_DOCS_ROOT, "llms.txt")

LLMS_TXT_PACKAGED_CHAPTERS = Dir.glob(File.join(LLMS_TXT_MANUAL_DIR, "*.md"))
                                .filter_map { |path| File.basename(path, ".md") unless path.end_with?("README.md") }
                                .sort.freeze

RSpec.describe "docs/llms.txt manual chapter sync (ADR-74)" do
  let(:index_body) { File.read(LLMS_TXT_PATH, encoding: "utf-8") }

  # `## Manual` runs until the next `## ` heading (`## Handbook`) — scoped so a chapter number that also
  # happens to exist in the handbook section (they share the `NN-slug` shape) is not cross-counted.
  let(:manual_section) { index_body[/^## Manual.*?(?=^## )/m] || "" }

  it "reads a non-trivial chapter list (guards against a glob that matches nothing)" do
    expect(LLMS_TXT_PACKAGED_CHAPTERS.size).to be >= 17
  end

  it "finds the ## Manual section (guards the scoping regex against a heading rename)" do
    expect(manual_section).not_to be_empty
  end

  it "names every packaged manual chapter" do
    missing = LLMS_TXT_PACKAGED_CHAPTERS.reject { |name| manual_section.include?("`#{name}`") }
    expect(missing).to be_empty,
                       "docs/manual/ chapters missing from docs/llms.txt: #{missing.inspect}\n" \
                       "Add a `- `<name>` — …` line under llms.txt's ## Manual section for each."
  end

  it "names no manual chapter that is not actually packaged (guards the reverse drift, a removed chapter)" do
    referenced = manual_section.scan(/^- `(\d{2}-[a-z0-9-]+)`/).flatten
    expect(referenced).not_to be_empty
    stale = referenced - LLMS_TXT_PACKAGED_CHAPTERS
    expect(stale).to be_empty,
                     "docs/llms.txt references manual chapters that no longer exist: #{stale.inspect}"
  end
end
