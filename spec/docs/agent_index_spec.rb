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
require "tmpdir"

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

# An ADR's own `Status:` header, in the two shapes the corpus writes it: a bare `Status: …` line, and
# ADR-60's list item `- Status: …`. The header runs to the first blank line — a paragraph, not a line.
AGENT_INDEX_ADR_STATUS_HEADER = /\A(?:- )?(?:\*\*)?Status(?:\*\*)?:\s*/

# Landing and non-landing vocabulary, read per sentence over both sources. Deliberately small: only
# words that state progress. A sentence carrying both is read clause by clause instead, because
# "WD1 implemented; WD2 deferred" is one sentence with two verdicts.
AGENT_INDEX_LANDED_WORDS = /\b(?:implemented|implements|landed|shipped|ships|complete|completed|done|in force)\b/i
AGENT_INDEX_OPEN_WORDS =
  /\b(?:deferred|open|pending|queued|remain|remains|remaining|unimplemented|paused|parked|gated)\b/i
# "not yet implemented" is a non-landing claim wearing a landing verb, and "partially implemented" is
# neither verdict — both sources say "partial" about the same item and would otherwise read as a
# disagreement (ADR-58 WD1). Anything ambiguous is dropped rather than guessed: this gate exists to
# catch two sources contradicting each other, and a firing on agreeing prose teaches authors to
# route around it.
AGENT_INDEX_NEGATED_LANDING = /\b(?:not|never|no)\s+(?:yet\s+)?(?:implemented|landed|shipped)/i
AGENT_INDEX_AMBIGUOUS_PROGRESS = /\bpartial/i

# The working-decision / slice identifiers both sources name: `WD1`, `WD1–WD6`, `WD1+WD2`, `slice 4`,
# `slices 1-4`, `slices A + B`. A slice name is a bare number or a single capital letter, never a
# following word — `slices this` is prose, not slice S.
AGENT_INDEX_WD_RANGE = /\bWD\s?(\d+)\s*[-–—]\s*WD\s?(\d+)/i
AGENT_INDEX_WD_LIST = /\bWD(\d+(?:\s*\+\s*WD?\d+)*)/i
AGENT_INDEX_SLICE_RANGE = /\bslices?\s+(\d+)\s*[-–—]\s*(\d+)/i
AGENT_INDEX_SLICE_LIST = /\bslices?\s+((?:\d+|[A-Z])(?:\s*\+\s*(?:\d+|[A-Z]))*)\b/i

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

  # The `Status:` paragraph of one ADR file, header prefix stripped. `nil` when the file has no such
  # header at all — the state nothing in the repo could see before #939.
  def adr_status_header(path)
    lines = File.readlines(path, encoding: "utf-8").map(&:chomp)
    start = lines.index { |line| line.match?(AGENT_INDEX_ADR_STATUS_HEADER) }
    return nil unless start

    paragraph = []
    lines[start..].each do |line|
      break if line.strip.empty?

      paragraph << line
    end
    paragraph.join(" ").sub(AGENT_INDEX_ADR_STATUS_HEADER, "")
  end

  def adr_status_headers
    Dir[AGENT_INDEX_ADR_GLOB].to_h { |path| [File.basename(path)[/\A\d+/].to_i, adr_status_header(path)] }
  end

  def adr_status_word(text)
    text&.delete("*")&.[](AGENT_INDEX_STATUS_WORD)
  end

  # The WD / slice identifiers named in one clause, normalized so `slices 1-4` and `slice 1 + slice 4`
  # compare as the same vocabulary on both sides.
  def adr_progress_ids(clause)
    ids = []
    clause.scan(AGENT_INDEX_WD_RANGE) { |low, high| ids.concat((low.to_i..high.to_i).map { |n| "WD#{n}" }) }
    clause.scan(AGENT_INDEX_WD_LIST) { |group,| group.scan(/\d+/) { |n| ids << "WD#{n}" } }
    clause.scan(AGENT_INDEX_SLICE_RANGE) { |low, high| ids.concat((low.to_i..high.to_i).map { |n| "slice #{n}" }) }
    clause.scan(AGENT_INDEX_SLICE_LIST) do |group,|
      group.split(/\s*\+\s*/).each { |name| ids << "slice #{name.upcase}" }
    end
    ids.uniq
  end

  # Split one status text into the identifiers it records as landed and the ones it records as still
  # open. A sentence with a single verdict lends it to every identifier it names (ADR-90 writes
  # "Implemented: … (WD1); … (WD2); … (WD3)"); a sentence with both is read clause by clause.
  def adr_progress_claims(text)
    landed = []
    still_open = []
    text.delete("*").split(/(?<=\.)\s+(?=[A-Z(`])/).each do |sentence|
      clauses = if sentence.match?(AGENT_INDEX_LANDED_WORDS) && sentence.match?(AGENT_INDEX_OPEN_WORDS)
                  sentence.split(/;\s+/)
                else
                  [sentence]
                end
      clauses.each do |clause|
        next if clause.match?(AGENT_INDEX_NEGATED_LANDING) || clause.match?(AGENT_INDEX_AMBIGUOUS_PROGRESS)

        landed.concat(adr_progress_ids(clause)) if clause.match?(AGENT_INDEX_LANDED_WORDS)
        still_open.concat(adr_progress_ids(clause)) if clause.match?(AGENT_INDEX_OPEN_WORDS)
      end
    end
    { landed: landed.uniq.sort, open: (still_open - landed).uniq.sort }
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

  # The ADR corpus ran two mutually ungated status sources: each ADR's own `Status:` header, and its
  # row in docs/adr/README.md. The 2026-09-09 corpus audit
  # (docs/notes/20260909-adr-corpus-audit.md § 4) found that this is the structural cause of its
  # largest finding category — roughly twenty ADRs still recording as unbuilt something that shipped.
  # Neither source was ever compared to the other, so both were free to drift; nothing in spec/ even
  # parsed the header, and ADR-60 had been written in a different shape with nothing noticing.
  #
  # These axes compare the two sources against each other. They do not (and cannot) check either
  # against the implementation — an ADR and its row that are stale in the same direction still pass,
  # which is what the #940 sweep is for. The comparison is deliberately conservative: it fails on a
  # contradiction, not on a difference in detail, because the README row is a capped status cell
  # (ADR-97 WD2) and the header is a paragraph — the row naming fewer working decisions than the
  # header is economy, not drift.
  describe "each ADR's Status: header against its docs/adr/README.md row" do
    let(:headers) { adr_status_headers }
    let(:rows) { readme.to_h { |entry| [entry[:number], entry[:status]] } }

    it "gives every ADR a parseable Status: header" do
      missing = headers.select { |_number, text| text.nil? || text.strip.empty? }.keys
      expect(missing).to be_empty,
                         "Every ADR states its own status, as `Status: …` or `- Status: …` before the " \
                         "first blank line. Without a header there is nothing for its README row to " \
                         "agree with. Missing: #{missing.map { |n| "ADR-#{n}" }.join(', ')}"
    end

    it "opens both sources with the same status word" do
      disagreements = headers.filter_map do |number, text|
        next if text.nil?

        from_header = adr_status_word(text)
        from_row = adr_status_word(rows[number].to_s)
        next if from_header && from_header == from_row

        "  ADR-#{number}: header says #{(from_header || text[0, 40]).inspect}, " \
          "README row says #{(from_row || rows[number].to_s[0, 40]).inspect}"
      end
      expect(disagreements).to be_empty,
                               "An ADR's Status: header and its README row are the corpus's two status " \
                               "sources and must agree on Accepted / Proposed / Superseded:\n" \
                               "#{disagreements.join("\n")}"
    end

    it "never credits a working decision or slice in the README that the ADR does not record as landed" do
      overclaimed = headers.filter_map do |number, text|
        next if text.nil?

        extra = adr_progress_claims(rows[number].to_s)[:landed] - adr_progress_claims(text)[:landed]
        next if extra.empty?

        "  ADR-#{number}: README row records #{extra.join(', ')} as landed; the ADR's own header does not"
      end
      expect(overclaimed).to be_empty,
                             "The index row credits work the ADR itself does not claim. Advance the ADR's " \
                             "Status: header, or drop the claim from the row:\n#{overclaimed.join("\n")}"
    end

    it "never records the same working decision or slice as landed in one source and open in the other" do
      contradictions = headers.flat_map do |number, text|
        next [] if text.nil?

        header_claims = adr_progress_claims(text)
        row_claims = adr_progress_claims(rows[number].to_s)
        (row_claims[:open] & header_claims[:landed]).map do |id|
          "  ADR-#{number}: the ADR's header records #{id} as landed; the README row records it as open"
        end + (header_claims[:open] & row_claims[:landed]).map do |id|
          "  ADR-#{number}: the README row records #{id} as landed; the ADR's header records it as open"
        end
      end
      expect(contradictions).to be_empty,
                                "The two status sources contradict each other on which work has landed. " \
                                "Fix whichever is stale — do not soften the wording:\n" \
                                "#{contradictions.join("\n")}"
    end
  end

  # The axes above pass on today's corpus, so they can only stay honest if the parser they run on is
  # itself pinned: a header shape it silently failed to read would make every comparison vacuous.
  describe "the Status: header parser" do
    def write_adr(dir, body)
      path = File.join(dir, "999-fixture.md")
      File.write(path, body)
      path
    end

    it "reads the bare-line and the list-item header shapes alike" do
      Dir.mktmpdir do |dir|
        bare = write_adr(dir, "# ADR-999\n\nStatus: **Accepted, 2026-01-01.** Body.\n\nMore.\n")
        expect(adr_status_word(adr_status_header(bare))).to eq("Accepted")

        listed = write_adr(dir, "# ADR-999\n\n- Status: Accepted (2026-01-01)\n\nMore.\n")
        expect(adr_status_word(adr_status_header(listed))).to eq("Accepted")
      end
    end

    it "returns nothing for an ADR with no Status: header" do
      Dir.mktmpdir do |dir|
        expect(adr_status_header(write_adr(dir, "# ADR-999\n\nNo status anywhere.\n"))).to be_nil
      end
    end

    it "separates landed identifiers from open ones within a sentence" do
      claims = adr_progress_claims("Accepted — WD1-WD3 implemented; WD4 deferred; slices 1+2 landed.")
      expect(claims[:landed]).to eq(["WD1", "WD2", "WD3", "slice 1", "slice 2"])
      expect(claims[:open]).to eq(["WD4"])
    end

    it "claims nothing from prose that states neither a landing nor a deferral" do
      expect(adr_progress_claims("Accepted, 2026-01-01. WD1 partially implemented; nothing else yet."))
        .to eq({ landed: [], open: [] })
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
