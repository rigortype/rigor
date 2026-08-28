# frozen_string_literal: true

require "spec_helper"
require "rigor/cli/doc_links"

# #430 — the documentation's links survive into `rigor docs` as keys the command can answer.
#
# The point of the scheme is that nothing is destroyed on either side: the repository keeps working
# relative links (so GitHub, and any reader with the tree, follow them normally), and the CLI reader
# gets the same edge rendered as something they can run. Two earlier shapes failed the other way —
# rewriting the source to `blob/master` URLs hardcoded a host and a branch in 297 places, and deleting
# the markup severed the coupling between documents that the links ARE.
RSpec.describe Rigor::CLI::DocLinks do
  def from(page) = File.expand_path("../../../docs/manual/#{page}", __dir__)

  describe ".rewrite" do
    it "turns a link to a packaged page into the name `rigor docs` already takes" do
      out = described_class.rewrite("see [Caching](12-caching.md).", from: from("04-diagnostics.md"))

      expect(out).to eq("see [Caching][manual/12-caching].")
    end

    it "turns a link to an unpackaged document into a key that still names it" do
      out = described_class.rewrite("see [ADR-103](../adr/103-effect-labels.md).", from: from("04-diagnostics.md"))

      expect(out).to eq("see [ADR-103][adr/103-effect-labels].")
    end

    # The anchor is the half that says WHERE in the page, and 72 shipped links carry one. Dropping it
    # was the first version's bug.
    it "keeps the anchor on the key" do
      out = described_class.rewrite("see [Size](12-caching.md#size-and-eviction).", from: from("04-diagnostics.md"))

      expect(out).to eq("see [Size][manual/12-caching#size-and-eviction].")
    end

    it "leaves an absolute URL and a bare anchor alone" do
      source = "[a](https://example.com/x) [b](#local)"

      expect(described_class.rewrite(source, from: from("11-ci.md"))).to eq(source)
    end

    # A CI template and a directory are not pages, but they are things a reader can be routed to, and
    # leaving them as relative paths would leave exactly the dead links this scheme exists to answer.
    it "names a non-page target by its repository path" do
      out = described_class.rewrite("[t](ci-templates/gitlab-ci.yml) and [d](../adr/)", from: from("11-ci.md"))

      expect(out).to eq("[t][docs/manual/ci-templates/gitlab-ci.yml] and [d][docs/adr/]")
    end
  end

  describe ".repository_path" do
    it "restores docs/ for a documentation key and leaves a top-level tree alone" do
      expect(described_class.repository_path("adr/103-effect-labels")).to eq("docs/adr/103-effect-labels.md")
      expect(described_class.repository_path("examples/README.md")).to eq("examples/README.md")
      expect(described_class.repository_path("docs/adr/")).to eq("docs/adr/")
    end

    it "refuses a key that could escape the tree" do
      expect(described_class.repository_path("../../etc/passwd")).to be_nil
      expect(described_class.repository_path("")).to be_nil
    end
  end
end
