# frozen_string_literal: true

# Verify that every relative markdown link in docs/handbook/ and docs/manual/ resolves to an existing file.
#
# External links (http/https) and pure in-page anchors (#section) are not checked — only relative file references.

require "spec_helper"

LINK_INTEGRITY_DOCS_ROOT = File.expand_path("../../docs", __dir__)

LINK_INTEGRITY_DOC_DIRS = [
  File.join(LINK_INTEGRITY_DOCS_ROOT, "handbook"),
  File.join(LINK_INTEGRITY_DOCS_ROOT, "manual")
].freeze

module LinkIntegrityHelpers
  def extract_relative_links(content, base_dir)
    # Strip fenced code blocks and inline code spans to avoid matching code like `[T any](x T)` as a markdown link.
    stripped = content
               .gsub(/```.*?```/m, "")
               .gsub(/`[^`\n]+`/, "")
    stripped.scan(/\[(?:[^\]]*)\]\(([^)]+)\)/).flatten.filter_map do |href|
      next if href.start_with?("http://", "https://", "#", "mailto:")

      path = href.split("#").first
      next if path.nil? || path.empty?

      File.expand_path(path, base_dir)
    end
  end
end

RSpec.describe "documentation link integrity" do
  extend LinkIntegrityHelpers
  include LinkIntegrityHelpers

  LINK_INTEGRITY_DOC_DIRS.each do |dir|
    Dir[File.join(dir, "**", "*.md")].each do |md_path|
      pre_check = extract_relative_links(
        File.read(md_path, encoding: "utf-8"),
        File.dirname(md_path)
      )
      next if pre_check.empty?

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
  end
end
