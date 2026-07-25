# frozen_string_literal: true

# Catch drift between docs/manual/ prose and the implementation it describes.  Five axes:
#
#   1. CLI subcommands — every key in CLI::HANDLERS must appear in the CLI reference, and vice versa.
#   2. Config keys — every top-level key in Configuration::DEFAULTS must be mentioned in the configuration reference.
#   3. Rule IDs — every ID in CheckRules::ALL_RULES must appear in the diagnostic catalogue or the handbook
#      errors chapter.
#   4. Rule documentation_url anchors — every RuleCatalog entry's `documentation_url` (ADR-65, a frozen public
#      contract) points at `04-diagnostics.md#rule-<id>`, so the catalogue must carry the matching anchor or the
#      published URL silently 404s within the page.
#   5. Declared diagnostic families — every family the type spec's identifier taxonomy declares resolves to a
#      real emitted id, or says in the row that it does not (ADR-92 WD4). Axes 1-4 all run impl -> doc; this
#      one runs doc -> impl, the direction that let five divergences ship unnoticed.
#   6. Expired version promises — no binding spec sentence speaks of an ALREADY-RELEASED version in the future
#      tense (#211). Axis 5's sibling: same doc -> impl direction, different failure mode. Each sentence it
#      catches was TRUE when written ("the merger lands in v0.1.0"), and nothing else in the corpus expires it.
#
# These checks are purely textual — no Rigor analysis needed.

require "spec_helper"

require "rigor/version"
require "rigor/cli"
require "rigor/configuration"
require "rigor/analysis/check_rules"
require "rigor/analysis/rule_catalog"

# Constants at file scope so nested describe/let blocks can resolve them.
MANUAL_DRIFT_DOCS_ROOT    = File.expand_path("../../docs", __dir__)
MANUAL_DRIFT_MANUAL_DIR   = File.join(MANUAL_DRIFT_DOCS_ROOT, "manual")
MANUAL_DRIFT_HANDBOOK_DIR = File.join(MANUAL_DRIFT_DOCS_ROOT, "handbook")

# Introspection helpers: emitted by the engine but documented in the handbook type-inspection chapter (05),
# not the diagnostic catalogue.
MANUAL_DRIFT_INTROSPECTION_RULES = %w[dump.type assert.type-mismatch].freeze

# Axis 5: families whose ids are contributed at runtime rather than by the engine, so the vocabulary cannot be
# enumerated here. `CheckRules.known_suppression_token?` takes the same under-warning stance for the same reason.
MANUAL_DRIFT_OPEN_VOCABULARY_FAMILIES = %w[plugin generated].freeze

# Axis 5: `| `family.*` | description |` rows of the taxonomy table → the declared prefix (dropping the `.*` /
# `.<provider>.*` tail) and whether the row carries the "as of this writing" status marker.
MANUAL_DRIFT_DECLARED_FAMILIES = File.read(
  File.join(MANUAL_DRIFT_DOCS_ROOT, "type-specification", "diagnostic-policy.md"), encoding: "utf-8"
).scan(/^\| `([a-z_]+)[.<][^`]*` \| (.*?) \|$/).map do |prefix, description|
  { prefix: prefix, marked: description.include?("as of this writing") }
end.freeze

# Axis 5: the engine's real diagnostic vocabulary — ALL_RULES plus every `rule:`-constructed literal in lib/,
# reduced to first dotted segments. ALL_RULES alone would miss the non-check families and report false gaps.
MANUAL_DRIFT_EMITTED_FAMILIES = (
  Rigor::Analysis::CheckRules::ALL_RULES +
  Dir[File.expand_path("../../lib/**/*.rb", __dir__)].flat_map do |rb|
    File.read(rb, encoding: "utf-8").scan(/rule: *"([a-z][a-z0-9_-]*(?:\.[a-z0-9_-]+)+)"/).flatten
  end
).map { |id| id.split(".").first }.uniq.freeze

# Axis 6: the binding corpus — the two spec trees CLAUDE.md says bind, and the only reader (the rigor-rs port)
# that cannot fall back on reading lib/ when a sentence misleads.
MANUAL_DRIFT_SPEC_CORPUS = (
  Dir[File.join(MANUAL_DRIFT_DOCS_ROOT, "type-specification", "**", "*.md")] +
  Dir[File.join(MANUAL_DRIFT_DOCS_ROOT, "internal-spec", "**", "*.md")]
).sort.freeze

# Axis 6: the future / pending markers that turn a version mention into a promise. Deliberately narrow — each
# can only be read as "this has not happened yet", and every past-tense form is excluded on purpose (`landed`,
# `added`, `shipped` are how a corrected sentence reads, so matching them would fight the fix). `yet` alone is
# excluded too: it is common in settled prose ("not yet recognised" describes shipped fail-soft behaviour).
MANUAL_DRIFT_PENDING_MARKERS = /\b(will|lands?|introduces?|adds?|plans? to|ships? in|is scheduled)\b/i

# Axis 6: only a fully-pinned version can expire. `v0.1.x` / `v1` name a line, not a release, and a sentence
# about a line stays true as the line grows — the corpus uses that spelling deliberately for open work.
MANUAL_DRIFT_VERSION_LITERAL = /\bv?(\d+\.\d+\.\d+)\b/

# Axis 6: the version must be GOVERNED by the marker, not merely present in the same sentence. Every real
# finding reads as one phrase ("the merger lands in v0.1.0", "v0.1.0 will define …", "v0.1.0's plugin API adds
# it"); a sentence that names an old version for history and a pending marker for something else is not a
# promise about that version ("the v0.0.9 per-method carry-over … lands in a separate v0.1.x ticket" — the
# first live false positive this axis produced). A short window in either direction separates the two.
MANUAL_DRIFT_PROMISE_WINDOW = 40

# Axis 6: the release a promise is measured against.
MANUAL_DRIFT_CURRENT_VERSION = Gem::Version.new(Rigor::VERSION)

# Axis 6: the versions a sentence promises something about — every pinned version sitting within
# {MANUAL_DRIFT_PROMISE_WINDOW} characters of a pending marker, in either direction. Empty for a sentence that
# makes no promise, whatever versions it happens to mention.
def manual_drift_promised_versions(sentence)
  markers = sentence.enum_for(:scan, MANUAL_DRIFT_PENDING_MARKERS).map { Regexp.last_match.begin(0) }
  return [] if markers.empty?

  sentence.enum_for(:scan, MANUAL_DRIFT_VERSION_LITERAL).filter_map do
    match = Regexp.last_match
    next unless markers.any? { |m| (match.begin(0) - m).abs <= MANUAL_DRIFT_PROMISE_WINDOW }

    Gem::Version.new(match[1])
  end
end

# Axis 6: a document's own sentences, whitespace-normalised. The corpus is hard-wrapped at ~100 columns, so a
# promise routinely straddles a line break ("the merger lands in\nv0.1.0 will define …") and a line-based scan
# would miss exactly the sentences this axis exists to catch. Fenced code blocks are dropped: a version string
# inside an example is data, not a claim.
#
# List items and table rows are split as their own units before the join, or a marker in one bullet would pair
# with a version literal in its neighbour — the axis would then report a sentence nobody wrote. That was the
# first thing this check got wrong when it was run against the live corpus.
def manual_drift_sentences(path)
  body = File.read(path, encoding: "utf-8").gsub(/^```.*?^```/m, "")
  body.split(/\n[ \t]*\n/).flat_map do |block|
    block.split(/^(?=[ \t]*(?:[-*+]|\d+\.|\|)\s)/).flat_map do |unit|
      unit.gsub(/\s+/, " ").strip.split(/(?<=[.:])\s+(?=[A-Z`*\[(])/)
    end
  end
end

RSpec.describe "manual accuracy" do
  # ── 1. CLI subcommand coverage ──────────────────────────────────

  describe "CLI subcommands (02-cli-reference.md)" do
    let(:handler_keys) { Rigor::CLI::HANDLERS.keys }
    let(:cli_doc) { File.read(File.join(MANUAL_DRIFT_MANUAL_DIR, "02-cli-reference.md"), encoding: "utf-8") }

    it "every HANDLERS subcommand is mentioned in the reference" do
      undocumented = handler_keys.reject do |cmd|
        cli_doc.include?("`rigor #{cmd}`") || cli_doc.include?("`#{cmd}`")
      end
      expect(undocumented).to be_empty,
                              "CLI::HANDLERS keys not mentioned in 02-cli-reference.md: " \
                              "#{undocumented.inspect}\nAdd a section for each missing subcommand."
    end
  end

  # ── 2. Config key coverage ───────────────────────────────────────

  describe "configuration keys (03-configuration.md)" do
    let(:top_level_keys) { Rigor::Configuration::DEFAULTS.keys }
    let(:config_doc) { File.read(File.join(MANUAL_DRIFT_MANUAL_DIR, "03-configuration.md"), encoding: "utf-8") }

    it "every DEFAULTS top-level key is mentioned in the reference" do
      missing = top_level_keys.reject do |key|
        # Accept backtick forms, YAML-key form (key:), or dot-notation prefix (cache.path, bundler.lockfile, …).
        config_doc.include?("`#{key}`") ||
          config_doc.include?("`#{key}:`") ||
          config_doc.include?("#{key}:") ||
          config_doc.include?("#{key}.")
      end
      expect(missing).to be_empty,
                         "Configuration::DEFAULTS keys not mentioned in 03-configuration.md: " \
                         "#{missing.inspect}\nAdd documentation for each missing key."
    end
  end

  # ── 3. Rule ID coverage ──────────────────────────────────────────

  describe "diagnostic rule IDs (04-diagnostics.md + handbook/08)" do
    let(:all_rules) { Rigor::Analysis::CheckRules::ALL_RULES }
    let(:combined_doc) do
      File.read(File.join(MANUAL_DRIFT_MANUAL_DIR, "04-diagnostics.md"), encoding: "utf-8") +
        File.read(File.join(MANUAL_DRIFT_HANDBOOK_DIR, "08-understanding-errors.md"), encoding: "utf-8")
    end

    it "every CheckRules::ALL_RULES entry appears in the diagnostic docs" do
      missing = (all_rules - MANUAL_DRIFT_INTROSPECTION_RULES).reject { |r| combined_doc.include?(r) }
      expect(missing).to be_empty,
                         "Rule IDs in ALL_RULES not mentioned in diagnostic docs: #{missing.inspect}\n" \
                         "Add each rule to manual/04-diagnostics.md or handbook/08-understanding-errors.md."
    end
  end

  # ── 4. Rule documentation_url anchor integrity (ADR-65) ──────────

  describe "rule documentation_url anchors (04-diagnostics.md)" do
    let(:catalogue_doc) { File.read(File.join(MANUAL_DRIFT_MANUAL_DIR, "04-diagnostics.md"), encoding: "utf-8") }

    # `RuleCatalog#documentation_url` is a frozen public contract (ADR-65): it points every built-in rule at
    # `04-diagnostics.md#rule-<id-dashed>`, resolved on GitHub by an explicit `<a id="rule-…">` anchor (the
    # rule ids do not slugify to their headings, so the anchor tag is the only thing that makes the URL land).
    # A rule added or renamed without its anchor ships a URL that 404s within the page — this guards it.
    it "every RuleCatalog entry's documentation_url anchor exists in the catalogue" do
      missing = Rigor::Analysis::RuleCatalog.all.reject do |entry|
        catalogue_doc.include?(%(id="#{Rigor::Analysis::RuleCatalog.doc_anchor(entry.id)}"))
      end
      expect(missing.map(&:id)).to be_empty,
                                   "RuleCatalog rules whose documentation_url anchor is missing from " \
                                   "04-diagnostics.md: #{missing.map(&:id).inspect}\n" \
                                   "Add `<a id=\"rule-<id-with-dots-as-dashes>\"></a>` for each."
    end
  end

  # ── 5. Declared diagnostic families resolve (ADR-92 WD4) ─────────
  #
  # The four axes above all run impl → doc ("every ALL_RULES id appears in the catalogue"). This one runs
  # doc → impl, which is the direction that let five spec/implementation divergences ship unnoticed: the type
  # spec declared families (`static.*`, `compat.*`, `hint.*`, `generated.*`) that have never had a single
  # implemented identifier, and no gate could see it — an unimplemented diagnostic is silence, and every
  # analysis gate is false-positive-oriented.
  #
  # Per ADR-92 the taxonomy in `diagnostic-policy.md` may claim an identifier space without implementing it,
  # but it must then say so: a family row either resolves to a real emitted id or carries a bolded status
  # marker. The recognised marker is the phrase "as of this writing" — the corpus's existing status idiom
  # (`inference-budgets.md`'s unwired `budgets:` table uses it), covering both "Reserved" (claimed, never
  # implemented) and "Not a diagnostic family" (implemented, reaches the user through another surface).
  #
  # The comparison reads the FULL emitted vocabulary, not `ALL_RULES` alone. `CheckRules` owns 26 ids; the
  # non-check families (`dynamic.*`, `pre-eval.*`, `rbs.coverage.*`, `rbs_extended.*`) are emitted elsewhere
  # and admitted per-family by `CheckRules.known_suppression_token?`. Reading only `ALL_RULES` here would
  # report those families as false gaps.
  describe "declared diagnostic families (diagnostic-policy.md § Identifier taxonomy)" do
    it "parses the taxonomy table (guards the regex against a table reformat)" do
      expect(MANUAL_DRIFT_DECLARED_FAMILIES.map { |f| f[:prefix] }).to include("call", "flow", "static", "hint")
    end

    MANUAL_DRIFT_DECLARED_FAMILIES
      .reject { |f| f[:marked] || MANUAL_DRIFT_OPEN_VOCABULARY_FAMILIES.include?(f[:prefix]) }
      .each do |family|
        it "`#{family[:prefix]}.*` has at least one implemented diagnostic id" do
          expect(MANUAL_DRIFT_EMITTED_FAMILIES).to include(family[:prefix]),
                                                   "diagnostic-policy.md declares the `#{family[:prefix]}.*` " \
                                                   "family, but no diagnostic under that prefix is emitted " \
                                                   "anywhere in lib/.\nPer ADR-92: implement an id, narrow the " \
                                                   "row, or mark the row with a bolded status containing " \
                                                   "\"as of this writing\"."
        end
      end

    it "no family carries a status marker while emitting ids (the marker must expire)" do
      stale = MANUAL_DRIFT_DECLARED_FAMILIES.select do |f|
        f[:marked] && MANUAL_DRIFT_EMITTED_FAMILIES.include?(f[:prefix])
      end
      expect(stale.map { |f| f[:prefix] }).to be_empty,
                                              "Families still marked in diagnostic-policy.md that now emit " \
                                              "real ids: #{stale.map { |f| f[:prefix] }.inspect}\n" \
                                              "Drop the status marker — the family shipped."
    end
  end

  # ── 6. Expired version promises (#211) ──────────────────────────
  #
  # The class this catches is not axis 5's. A clause axis 5 catches was never true; a sentence here was true
  # the day it was written and rotted on release day — "the merger lands in v0.1.0" (written at v0.0.9, still
  # in the document at v0.3.0 four sections above the note that it shipped). The comparison is decidable, which
  # is what makes this gateable where ADR-92 WD1 leaves the prose body ungated: a version literal against
  # `Rigor::VERSION`, not a judgement about whether a clause is satisfied. A sentence naming a version we have
  # NOT reached is a legitimate plan and passes.
  describe "expired version promises (spec corpus)" do
    it "reads a non-trivial corpus (guards against a glob that matches nothing)" do
      expect(MANUAL_DRIFT_SPEC_CORPUS.size).to be > 20
    end

    # The axis is silence-shaped: once the corpus is clean it passes forever, including if the detector
    # silently stops detecting. These pin it against the sentences that motivated it (all real, all from the
    # #163 sweep) and against the shapes it must NOT fire on.
    describe "the detector itself" do
      it "fires on a promise about a released version" do
        [
          "The merger that lands in v0.1.0 will define a tagged element form.",
          "It is the substrate the v0.1.0 plugin API will be designed against.",
          "v0.1.0's plugin API adds it as a separate concern."
        ].each do |sentence|
          expect(manual_drift_promised_versions(sentence).map(&:to_s)).to eq(["0.1.0"]), sentence
        end
      end

      it "stays silent on history, on release lines, and on versions we have not reached" do
        {
          "past tense" => "The merger landed in v0.1.0 alongside the plugin API.",
          "release line" => "That work is descoped and lands in a separate v0.1.x ticket.",
          "distant mention" => "Re-attempt the v0.0.9 per-method Reflection cache carry-over, per ADR-7 " \
                               "§ Slice 6-D, because that work is descoped and lands in another ticket.",
          "no version" => "The catalogue will grow as later slices promote more nodes."
        }.each do |shape, sentence|
          expect(manual_drift_promised_versions(sentence)).to be_empty, shape
        end
      end

      it "lets a genuine plan through (a version we have not released)" do
        promised = manual_drift_promised_versions("The identifiers will freeze as public vocabulary in v9.0.0.")
        expect(promised.map(&:to_s)).to eq(["9.0.0"])
        expect(promised.none? { |v| v <= MANUAL_DRIFT_CURRENT_VERSION }).to be(true)
      end
    end

    MANUAL_DRIFT_SPEC_CORPUS.each do |path|
      it "#{path.sub(MANUAL_DRIFT_DOCS_ROOT.to_s, '').delete_prefix('/')} makes no promise about a released version" do
        relative = path.sub("#{MANUAL_DRIFT_DOCS_ROOT}/", "")
        expired = manual_drift_sentences(path).select do |sentence|
          manual_drift_promised_versions(sentence).any? { |v| v <= MANUAL_DRIFT_CURRENT_VERSION }
        end

        expect(expired).to be_empty,
                           "#{relative} speaks of an already-released version " \
                           "(current: #{Rigor::VERSION}) in " \
                           "the future tense:\n\n" \
                           "#{expired.map { |s| "  - #{s}" }.join("\n\n")}\n\n" \
                           "Each sentence was true when written and is not now. Rewrite it in the past tense " \
                           "if the work shipped, or — if it did not — say so at the point of declaration " \
                           "(ADR-92 WD3) and name the release line (`v0.4.x`) rather than a pinned version, " \
                           "which cannot expire."
      end
    end
  end
end
