# frozen_string_literal: true

require "spec_helper"
require "rigor/cli/doc_links"

# Issue #430 — every link in the shipped documentation must reach the reader who has only the gem.
#
# `spec/docs/link_integrity_spec.rb` checks that relative links resolve in the CHECKOUT, where every
# target exists. An installed gem is a smaller tree: `rigortype.gemspec` ships `docs/manual/**` and
# `docs/handbook/**` and not `docs/adr/`, `docs/type-specification/`, `docs/internal-spec/`,
# `examples/`, `plugins/*/README.md` or `docs/notes/`. 284 links point into those.
#
# The links stay. They are the coupling between documents — which one explains what — and both of the
# other repairs cost more than they fixed: rewriting them to `blob/master` URLs put a host, an
# organisation and a branch into 297 places and sent a v0.3.5 reader to a document that had moved on,
# while deleting the markup severed the coupling and left a bare `ADR-103` going nowhere.
#
# Instead `rigor docs` rewrites them on the way out ({Rigor::CLI::DocLinks}), into keys it can answer:
# a packaged page prints, an unpackaged one is routed to its repository path. So what this file checks
# is not "no link points outside the package" but the property that makes that safe — **every link a
# shipped page carries turns into a key `rigor docs` resolves**, whether by printing or by routing.
RSpec.describe "packaged documentation links" do
  def packaged
    @packaged ||= Gem::Specification.load(File.expand_path("../../rigortype.gemspec", __dir__)).files.to_set
  end

  def repo_root
    @repo_root ||= File.expand_path("../..", __dir__)
  end

  def shipped_docs
    packaged.select { |file| file.end_with?(".md") && file.start_with?("docs/") }.sort
  end

  # Every relative link a shipped page carries, as `[document, target]`.
  def relative_links
    shipped_docs.flat_map do |doc|
      File.read(File.join(repo_root, doc))
          .scan(/\]\((?!https?:|mailto:|#)([^)#\s]+)(?:#[^)\s]*)?\)/)
          .flatten
          .map { |target| [doc, target] }
    end
  end

  it "carries a plausible number of links, so these checks are not vacuous" do
    expect(shipped_docs.length).to be >= 70
    expect(relative_links.length).to be >= 200
  end

  # The one that would have caught the original bug, stated as the property rather than the symptom.
  it "renders every link as a key `rigor docs` can answer" do
    unanswerable = relative_links.filter_map do |doc, target|
      key = Rigor::CLI::DocLinks.key_for(target, File.dirname(File.join(repo_root, doc)))
      next "#{doc} → #{target} (points outside the repository)" if key.nil?
      # Answerable one of two ways: the page is packaged and prints, or the key names a path that
      # exists and the reader is routed to it.
      next if packaged.include?("docs/#{key}.md")

      path = Rigor::CLI::DocLinks.repository_path(key)
      next if path && File.exist?(File.join(repo_root, path))

      "#{doc} → #{target} (key `#{key}` names nothing)"
    end

    expect(unanswerable).to be_empty,
                            "`rigor docs` hands these keys to a reader and cannot answer them:\n  " \
                            "#{unanswerable.first(20).join("\n  ")}"
  end

  # The scheme's whole benefit is that the source needs no host in it. One pointer per README is the
  # allowance; everything else routes through `DocLinks::REPOSITORY`.
  def repo_url_allowed
    {
      "docs/manual/README.md" => "one pointer saying where the unpackaged documents live",
      "docs/handbook/README.md" => "the same pointer for the handbook",
      "docs/manual/03-configuration.md" => "a `$schema` URL an editor fetches, not a citation",
      "docs/manual/08-skills.md" => "the argument of an `npx skills add` command the reader runs"
    }
  end

  it "keeps the repository host out of the documentation body" do
    offenders = shipped_docs.reject { |doc| repo_url_allowed.key?(doc) }.filter_map do |doc|
      hits = File.read(File.join(repo_root, doc))
                 .scan(%r{https://github\.com/rigortype/rigor/(?:blob|tree|raw)/master/[^)>\s]+})
      "#{doc}: #{hits.length} (#{hits.first})" unless hits.empty?
    end

    expect(offenders).to be_empty, "link the document relatively and let `rigor docs` route it — a " \
                                   "`master` URL pins a host, a branch, and the wrong version:\n  " \
                                   "#{offenders.join("\n  ")}"
  end
end
