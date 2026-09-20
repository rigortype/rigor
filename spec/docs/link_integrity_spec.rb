# frozen_string_literal: true

# Verify that every relative markdown link across the shipping docs/ tree resolves to an existing file.
#
# Covers the whole `docs/` tree EXCEPT two deliberately-excluded classes (see LINK_INTEGRITY_EXCLUDE):
#   - `docs/notes/` — transient review/session memos, not shipping docs; they carry links to external
#     papers and root-relative paths that are not maintained.
#   - `docs/CHANGELOG-0.*.x.md` — frozen historical changelog archives split out of the root CHANGELOG.md;
#     their links are relative to the repo root as authored, and several targets have since been
#     renamed/removed. Rewriting a frozen historical record is out of scope.
#
# External links (http/https) and pure in-page anchors (#section) are not checked — only relative file
# references. A trailing `:line` / `:line:col` position suffix (a `file.rb:42` source pointer) is stripped
# before the existence check.
#
# One class of external link IS gated: a SELF-referential GitHub URL, `github.com/rigortype/rigor/<blob|tree|
# raw>/<ref>/…`. Its `<ref>` is a git ref in this repository, so it can be checked against an in-repo
# authority without a network call — and it is the class that broke in #438, where four surfaces (the emitted
# `documentation_url`, the `.rigor.yml` init template, and the VS Code extension's manifest + README) named a
# `main` branch this repository has never had. Every one of them 404ed for as long as it shipped.

require "spec_helper"

LINK_INTEGRITY_DOCS_ROOT = File.expand_path("../../docs", __dir__)
LINK_INTEGRITY_REPO_ROOT = File.expand_path("../..", __dir__)

# The `references/` git submodules hold vendored upstream sources. Contributors check them out, but CI
# does not (the test job runs without submodules), so a link into `references/` is legitimately present
# locally yet absent in CI — never gate it here.
LINK_INTEGRITY_REFERENCES_ROOT = File.expand_path("../../references", __dir__)

# Paths (relative to docs/) whose links are intentionally not gated — see the header comment.
LINK_INTEGRITY_EXCLUDE = %r{\A(notes/|CHANGELOG-0\.\d+\.x\.md\z)}

# The repository's default branch, read from the CI workflow's push trigger. That is the authority available
# offline: CI gates pushes to the default branch by name, so a rename that skipped this file would leave the
# project with no CI at all — the one place the branch name cannot go stale unnoticed.
LINK_INTEGRITY_DEFAULT_BRANCH = File.read(
  File.join(LINK_INTEGRITY_REPO_ROOT, ".github", "workflows", "ci.yml"), encoding: "utf-8"
)[/^\s*branches:\s*\[\s*([\w.-]+)\s*\]/, 1]

# A self-referential GitHub URL and the git ref it names.
LINK_INTEGRITY_SELF_REF_URL = %r{https://github\.com/rigortype/rigor/(?:blob|tree|raw)/([\w.-]+)/}

# The surfaces gated for self-referential refs: everything a user or an editor can be handed. `docs/notes/` and
# the frozen changelog archives are excluded for the same reasons as above — a note records what a URL said at
# the time, and rewriting a frozen record to satisfy a gate would falsify it.
LINK_INTEGRITY_SELF_REF_FILES = Dir.chdir(LINK_INTEGRITY_REPO_ROOT) do
  Dir.glob(
    %w[
      README.md CONTRIBUTING.md rigortype.gemspec
      lib/**/*.rb exe/* schemas/*.json
      editors/*/*.md editors/*/package.json editors/*/src/**/*.ts
      skills/**/*.md docs/**/*.md plugins/**/*.md examples/**/*.md
      .github/workflows/*.yml
    ]
  ).grep_v(%r{\Adocs/(notes/|CHANGELOG-0\.\d+\.x\.md\z)}).sort
end.freeze

module LinkIntegrityHelpers
  def extract_relative_links(content, base_dir)
    # Strip fenced code blocks and inline code spans to avoid matching code like `[T any](x T)` as a markdown link.
    stripped = content
               .gsub(/```.*?```/m, "")
               .gsub(/`[^`\n]+`/, "")
    stripped.scan(/\[(?:[^\]]*)\]\(([^)]+)\)/).flatten.filter_map do |href|
      next if href.start_with?("http://", "https://", "#", "mailto:")

      # Drop a `#anchor` fragment and any trailing `:line` / `:line:col` source-pointer suffix.
      path = href.split("#").first&.sub(/:\d+(?::\d+)?\z/, "")
      next if path.nil? || path.empty?

      resolved = File.expand_path(path, base_dir)
      # Links into the `references/` submodules are not gated (see LINK_INTEGRITY_REFERENCES_ROOT).
      next if resolved.start_with?("#{LINK_INTEGRITY_REFERENCES_ROOT}/")

      resolved
    end
  end
end

# The docs that actually generate a link-checking example below: not excluded, and carrying at least one
# relative link to check. Hoisted to a constant so the guard on its size can read it from inside an example.
LINK_INTEGRITY_LINKED_DOCS = begin
  helper = Object.new.extend(LinkIntegrityHelpers)
  Dir[File.join(LINK_INTEGRITY_DOCS_ROOT, "**", "*.md")].select do |md_path|
    next false if md_path.delete_prefix("#{LINK_INTEGRITY_DOCS_ROOT}/").match?(LINK_INTEGRITY_EXCLUDE)

    helper.extract_relative_links(File.read(md_path, encoding: "utf-8"), File.dirname(md_path)).any?
  end
end.freeze

RSpec.describe "documentation link integrity" do
  extend LinkIntegrityHelpers
  include LinkIntegrityHelpers

  LINK_INTEGRITY_LINKED_DOCS.each do |md_path|
    rel = md_path.delete_prefix("#{LINK_INTEGRITY_DOCS_ROOT}/")

    it "#{rel} — all relative links exist" do
      broken = extract_relative_links(
        File.read(md_path, encoding: "utf-8"),
        File.dirname(md_path)
      ).reject { |t| File.exist?(t) }
      expect(broken).to be_empty,
                        "Broken links in #{md_path.delete_prefix("#{LINK_INTEGRITY_DOCS_ROOT}/")}:\n" +
                        broken.map { |t| "  → #{t.delete_prefix("#{LINK_INTEGRITY_DOCS_ROOT}/")} " }.join("\n")
    end
  end

  # The per-file examples above are generated at load time, so a scan that matches nothing produces NO
  # example and this file reports green having checked nothing — moving `docs/` aside takes it from 251
  # examples to 3, with no failure and no count anyone asserts. The self-referential scan below already
  # carries this guard for its own corpus, and `packaged_link_integrity_spec.rb` carries it for both of
  # its own; this is the same pin for the larger corpus here.
  #
  # A floor rather than an exact count, because this corpus DOES grow: every new document with a relative
  # link adds one. Set close to the current 248 on purpose. 230 was still too loose: `docs/design/` (17)
  # and `docs/type-specification/` (18, the BINDING spec) each fit inside the slack, so either could be
  # excluded and land exactly on the boundary, green.
  it "generates a link-checking example for a plausible number of docs, so the above is not vacuous" do
    expect(LINK_INTEGRITY_LINKED_DOCS.size).to be >= 240
  end

  # Counting documents is not enough: the link extractor is a single point of failure that the document
  # count cannot see through. Relaxing the fenced-code stripper to `/```.*```/m` — a plausible
  # simplification — takes the links actually checked from 2899 to 2439 while only 7 documents drop out,
  # so 16% of the corpus silently stops being verified and every floor above still passes.
  #
  # The slack is sized for a structural loss, not a nibble: every extractor change that drops a whole
  # SHAPE of link goes red (tables −408, list items −614, `..` paths −1336, the greedy stripper −449),
  # while a 2% trim does not. It is deliberately not tighter, because `docs/adr/README.md` alone carries
  # 116 links and rewriting that index is a legitimate edit that should not have to touch this number.
  it "extracts a plausible number of links, so a weakened extractor cannot quietly shrink the corpus" do
    helper = Object.new.extend(LinkIntegrityHelpers)
    total = LINK_INTEGRITY_LINKED_DOCS.sum do |md_path|
      helper.extract_relative_links(File.read(md_path, encoding: "utf-8"), File.dirname(md_path)).size
    end

    expect(total).to be >= 2700
  end

  # The glob cannot silently miss a new document, but the EXCLUDE can silently drop a whole subtree, and
  # it is the one line an author edits to make a noisy directory go away: adding `manual/` to it takes the
  # scan from 248 documents to 200 with no failure. So state what the exclusion is allowed to cover rather
  # than only how much survives it. `docs/notes/` records what a URL said at the time and the frozen
  # changelog archives are a historical record — rewriting either to satisfy a gate would falsify it.
  it "excludes nothing beyond docs/notes/ and the frozen changelog archives" do
    excluded = Dir[File.join(LINK_INTEGRITY_DOCS_ROOT, "**", "*.md")]
               .map { |path| path.delete_prefix("#{LINK_INTEGRITY_DOCS_ROOT}/") }
               .grep(LINK_INTEGRITY_EXCLUDE)
    unexpected = excluded.reject { |rel| rel.start_with?("notes/") || rel.match?(/\ACHANGELOG-0\.\d+\.x\.md\z/) }

    expect(unexpected).to be_empty,
                          "LINK_INTEGRITY_EXCLUDE has grown past the two surfaces it documents, so " \
                          "these documents' links are no longer checked by anything:\n" +
                          unexpected.map { |rel| "  → #{rel}" }.join("\n")
  end

  # #438: a self-referential GitHub URL names a ref in THIS repository, so it is checkable offline — and it is
  # the only external link class where a rename here (not upstream) is what breaks it.
  describe "self-referential GitHub URLs" do
    it "reads the default branch out of the CI workflow (guards the parse)" do
      expect(LINK_INTEGRITY_DEFAULT_BRANCH).to eq("master")
    end

    it "scans a non-empty file set (guards the globs against a tree reshuffle)" do
      expect(LINK_INTEGRITY_SELF_REF_FILES).to include("rigortype.gemspec", "README.md",
                                                       "lib/rigor/analysis/rule_catalog.rb")
    end

    # A tag would resolve too, and is deliberately NOT allowed: `blob/v0.4.0/…` 404s for every build made
    # between the version bump and the tag push, which is precisely the window a contributor reads these URLs
    # in. Pin to the default branch, or drop the ref entirely and use the published docs host.
    it "all name the repository's default branch" do
      offenders = LINK_INTEGRITY_SELF_REF_FILES.filter_map do |path|
        refs = File.read(File.join(LINK_INTEGRITY_REPO_ROOT, path), encoding: "utf-8")
                   .scan(LINK_INTEGRITY_SELF_REF_URL).flatten.uniq
                   .reject { |ref| ref == LINK_INTEGRITY_DEFAULT_BRANCH }
        "  → #{path}: #{refs.join(', ')}" unless refs.empty?
      end
      expect(offenders).to be_empty,
                           "Self-referential GitHub URLs naming a ref other than " \
                           "`#{LINK_INTEGRITY_DEFAULT_BRANCH}` (these 404):\n#{offenders.join("\n")}"
    end
  end
end
