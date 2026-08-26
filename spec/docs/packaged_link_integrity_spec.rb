# frozen_string_literal: true

require "spec_helper"

# Issue #430 — link integrity against the PACKAGED file list, not the repository tree.
#
# `spec/docs/link_integrity_spec.rb` checks that every relative link resolves in the checkout, where
# every target exists. An installed gem is a different file set: `rigortype.gemspec` ships
# `docs/manual/**` and `docs/handbook/**` and not `docs/adr/`, `docs/type-specification/`,
# `docs/internal-spec/`, `examples/`, `plugins/*/README.md` or `docs/notes/`. A relative link from a
# shipped page into any of those is dead for every reader who installed Rigor rather than cloning it —
# which is all of them — and invisible in-repo. There were 284 such links across 66 shipped documents.
#
# So the rule is: a shipped document may link relatively only to another shipped document. Anything
# outside the package is named by its canonical URL, which resolves for a reader who has the gem and for
# one who has the repository. Shipping the missing trees was measured and rejected: `docs/adr/` alone is
# 2.1 MB against a 7.1 MB gem, and it would still leave the 128 links that point at `examples/`,
# `plugins/*/README.md`, `docs/notes/` and the like.
RSpec.describe "packaged documentation links" do
  def packaged
    @packaged ||= Gem::Specification.load(File.expand_path("../../rigortype.gemspec", __dir__)).files.to_set
  end

  def repo_root
    @repo_root ||= File.expand_path("../..", __dir__)
  end

  # `](target)` and `](target#anchor)`, skipping absolute URLs and bare anchors.
  def relative_links(doc)
    File.read(File.join(repo_root, doc))
        .scan(/\]\(([^)#\s]+)(?:#[^)\s]*)?\)/)
        .flatten
        .reject { |target| target.start_with?("http://", "https://", "mailto:") }
  end

  def resolve(doc, target)
    File.expand_path(target, File.dirname(File.join(repo_root, doc))).sub("#{repo_root}/", "")
  end

  def shipped_docs
    packaged.select { |file| file.end_with?(".md") }.sort
  end

  it "packages a plausible number of documents, so these checks are not vacuous" do
    expect(shipped_docs.length).to be >= 100
    expect(shipped_docs).to include("docs/manual/04-diagnostics.md", "docs/handbook/01-getting-started.md")
  end

  # The other half of the same rule, and the coverage this change would otherwise have removed. A
  # relative link into `docs/adr/` was at least validated in-repo by `link_integrity_spec`; rewriting it
  # to a URL takes it out of that spec's reach, so a rename would rot it silently. The target is a path
  # in THIS repository, so it can be checked without a network call.
  it "points every canonical repository URL at a path that exists" do
    prefix = %r{\Ahttps://github\.com/rigortype/rigor/(?:blob|tree)/master/}
    offenders = shipped_docs.flat_map do |doc|
      File.read(File.join(repo_root, doc))
          .scan(%r{\]\((https://github\.com/rigortype/rigor/(?:blob|tree)/master/[^)#\s]+)(?:#[^)\s]*)?\)})
          .flatten
          .reject { |url| File.exist?(File.join(repo_root, url.sub(prefix, ""))) }
          .map { |url| "#{doc} → #{url}" }
    end

    expect(offenders).to be_empty, "these URLs name a path this repository does not have:\n  " \
                                   "#{offenders.first(20).join("\n  ")}"
  end

  it "never links relatively from a shipped document to an unshipped one" do
    offenders = shipped_docs.flat_map do |doc|
      relative_links(doc).filter_map do |target|
        resolved = resolve(doc, target)
        next if packaged.include?(resolved)

        reason = File.exist?(File.join(repo_root, resolved)) ? "not packaged" : "does not exist"
        "#{doc} → #{target} (#{reason})"
      end
    end

    expect(offenders).to be_empty, lambda {
      "a reader who installed the gem cannot follow these; name the target by its canonical URL " \
        "(https://github.com/rigortype/rigor/blob/master/…) instead:\n  #{offenders.first(40).join("\n  ")}" \
        "#{"\n  … and #{offenders.length - 40} more" if offenders.length > 40}"
    }
  end
end
