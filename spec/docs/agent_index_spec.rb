# frozen_string_literal: true

# Gate CLAUDE.md's ADR list as an INDEX rather than a summary, per ADR-97.
#
# CLAUDE.md is loaded into context at the start of every session, so its ADR list is paid for by every
# session regardless of relevance. ADR-97's criterion: an unconditionally-loaded document carries only
# what a session cannot start without; per-ADR detail belongs behind a pointer, in the read-on-demand
# `docs/adr/README.md`.
#
# This axis exists because the rule regressed once already without one. Commit db8d01bf (2026-05-29)
# applied the identical compression by hand and left it to instruction; within seven weeks the list had
# regrown 8.7x, entirely via new ADRs entering at the then-current density. An economy rule with no
# mechanical gate is a temporary state, not a decision — so the gate is part of ADR-97, not a follow-up.

require "spec_helper"

AGENT_INDEX_CLAUDE_MD = File.expand_path("../../CLAUDE.md", __dir__)
AGENT_INDEX_ADR_README = File.expand_path("../../docs/adr/README.md", __dir__)

# The longest canonical ADR title today is 100 characters. This is a budget, not a derived optimum:
# if a title genuinely needs more, move the cap in ADR-97 rather than exempting an entry here.
AGENT_INDEX_TOPIC_MAX = 100

# `- [ADR-N](docs/adr/N-slug.md) — <topic>`
AGENT_INDEX_BULLET = %r{^- \[ADR-(\d+)\]\(docs/adr/([^)]+)\) — (.+)$}
# `| ADR-N | [Title](N-slug.md) | <status> |`
AGENT_INDEX_ADR_ROW = /^\| ADR-(\d+) \| \[.+?\]\((\d+-[^)]+\.md)\)/

# Progress vocabulary that belongs in docs/adr/README.md's status column, never in the index topic. An
# index entry names a subject; it does not track implementation state (which drifts — the second copy is
# what cost a dense summary per ADR).
#
# Deliberately narrow: only unambiguous *progress* markers. "deferred" / "rejected" / "proposed" are NOT
# here, because for an evaluation ADR the deferral or rejection IS the decision, not its progress —
# ADR-95 ("Homebrew distribution: deferred behind the single binary") and ADR-86 ("... (rejected;
# rigor-rs owns native speed)") are correct index topics. A gate that fires on a correct entry teaches
# authors to route around it.
AGENT_INDEX_STATUS_WORDS = /\b(?:implemented|landed|shipped|partially|in flight)\b|\bslice \d|\bwd\d|\d{4}-\d{2}-\d{2}/i

module AgentIndexHelpers
  def claude_md_adr_bullets
    File.read(AGENT_INDEX_CLAUDE_MD, encoding: "utf-8").each_line.filter_map do |line|
      next unless (m = line.chomp.match(AGENT_INDEX_BULLET))

      { number: m[1].to_i, slug: m[2], topic: m[3].strip }
    end
  end

  def adr_readme_entries
    File.read(AGENT_INDEX_ADR_README, encoding: "utf-8").each_line.filter_map do |line|
      next unless (m = line.match(AGENT_INDEX_ADR_ROW))

      { number: m[1].to_i, slug: m[2] }
    end
  end
end

RSpec.describe "CLAUDE.md ADR index (ADR-97)" do
  include AgentIndexHelpers

  let(:bullets) { claude_md_adr_bullets }
  let(:readme) { adr_readme_entries }

  it "carries one bullet per ADR" do
    expect(bullets).not_to be_empty
    expect(bullets.map { |b| b[:number] }.tally.select { |_, c| c > 1 }).to be_empty
  end

  it "keeps every topic within the #{AGENT_INDEX_TOPIC_MAX}-character cap" do
    over = bullets.select { |b| b[:topic].length > AGENT_INDEX_TOPIC_MAX }
    expect(over).to be_empty, lambda {
      "CLAUDE.md is loaded every session; its ADR list is an index, not a summary (ADR-97).\n" \
      "Put the detail in the ADR and its docs/adr/README.md row instead:\n" +
        over.map { |b| "  ADR-#{b[:number]}: #{b[:topic].length} chars (cap #{AGENT_INDEX_TOPIC_MAX})" }.join("\n")
    }
  end

  it "keeps implementation status out of the topics" do
    tainted = bullets.filter_map do |b|
      next unless (m = b[:topic].match(AGENT_INDEX_STATUS_WORDS))

      "  ADR-#{b[:number]}: #{m[0].inspect} — status belongs in docs/adr/README.md"
    end
    expect(tainted).to be_empty, "Status/progress detail in the CLAUDE.md ADR index (ADR-97):\n#{tainted.join("\n")}"
  end

  it "lists exactly the ADRs docs/adr/README.md indexes" do
    expect(bullets.map { |b| b[:number] }.sort).to eq(readme.map { |e| e[:number] }.sort)
  end

  it "links each ADR at the same slug docs/adr/README.md uses" do
    by_number = readme.to_h { |e| [e[:number], e[:slug]] }
    mismatched = bullets.filter_map do |b|
      expected = by_number[b[:number]]
      "  ADR-#{b[:number]}: CLAUDE.md=#{b[:slug]} README=#{expected}" if expected && expected != b[:slug]
    end
    expect(mismatched).to be_empty, "Slug mismatch between the two ADR indexes:\n#{mismatched.join("\n")}"
  end

  it "lists the ADRs in ascending order" do
    numbers = bullets.map { |b| b[:number] }
    expect(numbers).to eq(numbers.sort)
  end
end
