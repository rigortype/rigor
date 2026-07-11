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

require "spec_helper"

LINK_INTEGRITY_DOCS_ROOT = File.expand_path("../../docs", __dir__)

# The `references/` git submodules hold vendored upstream sources. Contributors check them out, but CI
# does not (the test job runs without submodules), so a link into `references/` is legitimately present
# locally yet absent in CI — never gate it here.
LINK_INTEGRITY_REFERENCES_ROOT = File.expand_path("../../references", __dir__)

# Paths (relative to docs/) whose links are intentionally not gated — see the header comment.
LINK_INTEGRITY_EXCLUDE = %r{\A(notes/|CHANGELOG-0\.\d+\.x\.md\z)}

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

RSpec.describe "documentation link integrity" do
  extend LinkIntegrityHelpers
  include LinkIntegrityHelpers

  Dir[File.join(LINK_INTEGRITY_DOCS_ROOT, "**", "*.md")].each do |md_path|
    rel = md_path.delete_prefix("#{LINK_INTEGRITY_DOCS_ROOT}/")
    next if rel.match?(LINK_INTEGRITY_EXCLUDE)

    pre_check = extract_relative_links(
      File.read(md_path, encoding: "utf-8"),
      File.dirname(md_path)
    )
    next if pre_check.empty?

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
end
