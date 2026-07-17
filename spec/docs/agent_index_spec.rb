# frozen_string_literal: true

# Gate the two ADR lists against what each is actually for, per ADR-97.
#
# Both had drifted into carrying a dense per-ADR essay that merely restates the ADR body:
#
#   - `AGENTS.md` is the contract, loaded into every session (Claude Code reads CLAUDE.md, which pulls
#     it in with `@AGENTS.md`), so its ADR list is paid for by every session regardless of relevance.
#     It is a **premise set**, not an index: only the ADRs an agent would otherwise get wrong without
#     knowing to look them up (the foundation / conceptual core, and the standing policies). Every
#     other ADR is a lookup, reached via docs/adr/README.md.
#   - `docs/adr/README.md` is the complete index, and its third column is headed **Status**. That
#     README's own "How to Read" declares the contract: `Accepted` / `Proposed` / `Superseded`, plus a
#     parenthetical for an in-flight implementation. It is a status, not a summary.
#
# These axes exist because the rule regressed once already without one. Commit db8d01bf (2026-05-29)
# applied the identical CLAUDE.md compression by hand and left it to instruction; within seven weeks the
# list had regrown 8.7x, entirely via new ADRs entering at the then-current density — and the same
# ratchet hit the README's status column over the same span (both files' entries are still compliant
# below ADR-40 and bloated above it). An economy rule with no mechanical gate is a temporary state, not
# a decision, so the gate is part of ADR-97 rather than a follow-up to it.

require "spec_helper"

AGENT_INDEX_AGENTS_MD = File.expand_path("../../AGENTS.md", __dir__)
AGENT_INDEX_ADR_README = File.expand_path("../../docs/adr/README.md", __dir__)
AGENT_INDEX_ADR_GLOB = File.expand_path("../../docs/adr/[0-9]*.md", __dir__)

# The longest canonical ADR title today is 100 characters. A budget, not a derived optimum: if a title
# genuinely needs more, move the cap in ADR-97 rather than exempting an entry here.
AGENT_INDEX_TOPIC_MAX = 100

# AGENTS.md's premise set is 10 today (ADR-0..5 + the four standing policies). The cap is the point, not
# the number: adding an 11th or 12th premise should cost a deliberate argument, because every session
# pays for it. Growing past this means a new *standing policy* landed, which is rare — a new ADR
# normally adds nothing here at all. If a 13th genuinely earns its place, move the cap in ADR-97.
AGENT_INDEX_PREMISE_MAX = 12

# Fits `Accepted (WD1-WD5 implemented, PR #85; supersedes ADR-54's rejected mtime fast-path)` with room
# to spare. The pre-ADR-97 status cells ran to 5,195 characters; the compliant pre-ADR-40 ones median 19.
AGENT_INDEX_STATUS_MAX = 200

# The session handoff (ADR-98 WD2): where things stand + what the next session does + what waits on the
# user. Today's is 62 lines; the pre-ADR-98 file hit 189 lines / 75KB by absorbing the backlog. A handoff
# that needs more than this is carrying another surface's content.
AGENT_INDEX_HANDOFF_MAX = 120

# `- [ADR-N](docs/adr/N-slug.md) — <topic>`
AGENT_INDEX_BULLET = %r{^- \[ADR-(\d+)\]\(docs/adr/([^)]+)\) — (.+)$}
# `| ADR-N | [Title](N-slug.md) | <status> |`
AGENT_INDEX_ADR_ROW = /^\| ADR-(\d+) \| \[.+?\]\((\d+-[^)]+\.md)\) \| (.*?) \|\s*$/

# The status vocabulary docs/adr/README.md's "How to Read" declares.
AGENT_INDEX_STATUS_WORD = /\A(?:Accepted|Proposed|Superseded)\b/

# Progress vocabulary that belongs in the README's status column, never in the AGENTS.md premise topic. An
# index entry names a subject; it does not track implementation state (which drifts — a second copy of
# the status is exactly what went stale on ADR-48 and ADR-73 before ADR-97).
#
# Deliberately narrow: only unambiguous *progress* markers. "deferred" / "rejected" / "proposed" are NOT
# here, because for an evaluation ADR the deferral or rejection IS the decision, not its progress —
# ADR-95 ("Homebrew distribution: deferred behind the single binary") and ADR-86 ("... (rejected;
# rigor-rs owns native speed)") are correct index topics. A gate that fires on a correct entry teaches
# authors to route around it.
AGENT_INDEX_PROGRESS_WORDS =
  /\b(?:implemented|landed|shipped|partially|in flight)\b|\bslice \d|\bwd\d|\d{4}-\d{2}-\d{2}/i

module AgentIndexHelpers
  def agents_md_adr_bullets
    File.read(AGENT_INDEX_AGENTS_MD, encoding: "utf-8").each_line.filter_map do |line|
      next unless (m = line.chomp.match(AGENT_INDEX_BULLET))

      { number: m[1].to_i, slug: m[2], topic: m[3].strip }
    end
  end

  def adr_readme_entries
    File.read(AGENT_INDEX_ADR_README, encoding: "utf-8").each_line.filter_map do |line|
      next unless (m = line.chomp.match(AGENT_INDEX_ADR_ROW))

      { number: m[1].to_i, slug: m[2], status: m[3].strip }
    end
  end
end

RSpec.describe "ADR index budgets (ADR-97)" do
  include AgentIndexHelpers

  let(:bullets) { agents_md_adr_bullets }
  let(:readme) { adr_readme_entries }

  describe "AGENTS.md ADR premise set" do
    it "lists each premise once" do
      expect(bullets).not_to be_empty
      expect(bullets.map { |b| b[:number] }.tally.select { |_, c| c > 1 }).to be_empty
    end

    it "stays within the #{AGENT_INDEX_PREMISE_MAX}-entry cap" do
      listed = bullets.map { |b| "ADR-#{b[:number]}" }.join(", ")
      expect(bullets.size).to be <= AGENT_INDEX_PREMISE_MAX,
                              "AGENTS.md loads into every session, so its ADR list is a premise set, not " \
                              "an index (ADR-97 WD1):\nonly the ADRs an agent would get wrong without " \
                              "knowing to look them up — the foundation / conceptual core, and the " \
                              "standing policies in force. Every other ADR is a lookup and belongs only " \
                              "in docs/adr/README.md.\n#{bullets.size} entries (cap " \
                              "#{AGENT_INDEX_PREMISE_MAX}): #{listed}"
    end

    it "keeps every topic within the #{AGENT_INDEX_TOPIC_MAX}-character cap" do
      over = bullets.select { |b| b[:topic].length > AGENT_INDEX_TOPIC_MAX }
      detail = over.map { |b| "  ADR-#{b[:number]}: #{b[:topic].length} chars (cap #{AGENT_INDEX_TOPIC_MAX})" }
      expect(over).to be_empty,
                      "AGENTS.md loads into every session; its ADR list is a premise set (ADR-97 WD1).\n" \
                      "Put the detail in the ADR body instead:\n#{detail.join("\n")}"
    end

    it "keeps implementation status out of the topics" do
      tainted = bullets.filter_map do |b|
        next unless (m = b[:topic].match(AGENT_INDEX_PROGRESS_WORDS))

        "  ADR-#{b[:number]}: #{m[0].inspect} — status belongs in docs/adr/README.md"
      end
      expect(tainted).to be_empty,
                         "Status/progress detail in the AGENTS.md ADR premises (ADR-97):\n#{tainted.join("\n")}"
    end

    it "lists only ADRs docs/adr/README.md indexes" do
      # A subset, deliberately: the complete index is docs/adr/README.md's job (ADR-97 WD1). This axis
      # catches a premise pointing at an ADR that does not exist, not a README ADR "missing" from here.
      orphans = bullets.map { |b| b[:number] } - readme.map { |e| e[:number] }
      expect(orphans).to be_empty,
                         "AGENTS.md names ADRs absent from docs/adr/README.md: #{orphans.inspect}"
    end

    it "links each ADR at the same slug docs/adr/README.md uses" do
      by_number = readme.to_h { |e| [e[:number], e[:slug]] }
      mismatched = bullets.filter_map do |b|
        expected = by_number[b[:number]]
        "  ADR-#{b[:number]}: AGENTS.md=#{b[:slug]} README=#{expected}" if expected && expected != b[:slug]
      end
      expect(mismatched).to be_empty, "Slug mismatch between the two ADR indexes:\n#{mismatched.join("\n")}"
    end

    it "lists the ADRs in ascending order" do
      numbers = bullets.map { |b| b[:number] }
      expect(numbers).to eq(numbers.sort)
    end
  end

  describe "docs/adr/README.md index" do
    it "indexes every ADR file in docs/adr/" do
      on_disk = Dir[AGENT_INDEX_ADR_GLOB].map { |p| File.basename(p)[/\A\d+/].to_i }
      expect(readme.map { |e| e[:number] }.sort).to eq(on_disk.sort)
    end

    # A blank line ends a markdown table. Five had accumulated between rows, so the index rendered as
    # six separate tables, each re-reading the next ADR row as its header — invisible for as long as the
    # cells were thousand-character essays nobody read rendered, and obvious the moment they were not.
    it "keeps the index table contiguous — a blank row would end it" do
      lines = File.readlines(AGENT_INDEX_ADR_README, encoding: "utf-8").map(&:chomp)
      first = lines.index { |l| l.start_with?("| ADR-") }
      last = lines.rindex { |l| l.start_with?("| ADR-") }
      expect(first).not_to be_nil

      breaks = (first..last).reject { |i| lines[i].start_with?("| ADR-") }
      detail = breaks.map { |i| "  line #{i + 1}: #{lines[i].inspect}" }
      expect(breaks).to be_empty,
                        "Non-row lines inside the ADR index table break its markdown rendering:\n" \
                        "#{detail.join("\n")}"
    end

    it "keeps every status cell within the #{AGENT_INDEX_STATUS_MAX}-character cap" do
      over = readme.select { |e| e[:status].length > AGENT_INDEX_STATUS_MAX }
      detail = over.map { |e| "  ADR-#{e[:number]}: #{e[:status].length} chars (cap #{AGENT_INDEX_STATUS_MAX})" }
      expect(over).to be_empty,
                      "This column is headed Status, and the README's own \"How to Read\" declares its contract:\n  " \
                      "Accepted / Proposed / Superseded, plus a parenthetical for an in-flight implementation.\n" \
                      "It is a status, not a summary — the criteria, rationale and measurements live in the ADR " \
                      "body (ADR-97 WD2). Over the cap:\n#{detail.join("\n")}"
    end

    it "starts every status cell with a declared status word" do
      bad = readme.reject { |e| e[:status].match?(AGENT_INDEX_STATUS_WORD) }
      detail = bad.map { |e| "  ADR-#{e[:number]}: #{e[:status][0, 60].inspect}" }
      expect(bad).to be_empty,
                     "Every status cell must open with Accepted / Proposed / Superseded " \
                     "(docs/adr/README.md \"How to Read\"):\n#{detail.join("\n")}"
    end

    it "lists the ADRs in ascending order" do
      numbers = readme.map { |e| e[:number] }
      expect(numbers).to eq(numbers.sort)
    end
  end

  describe "development-flow documents (ADR-98)" do
    it "keeps docs/ROADMAP.md dissolved" do
      # The backlog is GitHub Issues and release planning is Milestones (docs/agents/issue-tracker.md).
      # ROADMAP.md was deleted after per-item adjudication; recreating it is the regression ADR-98
      # exists to prevent — a tracked markdown backlog has no state machine, so it only accumulates.
      recreated = File.exist?(File.expand_path("../../docs/ROADMAP.md", __dir__))
      expect(recreated).to be(false),
                           "docs/ROADMAP.md has been recreated. The backlog belongs in GitHub Issues " \
                           "(ADR-98 WD1); a new planning document needs an ADR superseding ADR-98, not a file."
    end

    it "keeps the session handoff within its #{AGENT_INDEX_HANDOFF_MAX}-line cap" do
      lines = File.readlines(File.expand_path("../../docs/CURRENT_WORK.md", __dir__), encoding: "utf-8")
      expect(lines.size).to be <= AGENT_INDEX_HANDOFF_MAX,
                            "docs/CURRENT_WORK.md is a full-replace session handoff (ADR-98 WD2): what the next " \
                            "session should do, and nothing that outlives two sessions.\n" \
                            "#{lines.size} lines (cap #{AGENT_INDEX_HANDOFF_MAX}) — move backlog to issues, " \
                            "pitfalls to the workflow's skill, decisions to an ADR, measurements to docs/notes/."
    end
  end
end
