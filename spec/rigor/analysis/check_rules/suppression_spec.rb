# frozen_string_literal: true

require "spec_helper"

# The `CheckRules` suppression system — `filter_suppressed` and the `suppression.*` surveillance rules that
# guard it. Three layers compose (project `disable:`, file-level `# rigor:disable-file`, line-level
# `# rigor:disable`), and every marker is recognised only when it OPENS the comment, so a directive quoted
# in ordinary prose is prose (issue #306; normative in type-specification/diagnostic-policy.md §
# "Marker position within a comment"). Every suppressing example is paired with the same fixture
# un-suppressed, so a decline can never pass vacuously.
RSpec.describe "diagnostic suppression", type: :runner do
  def rules_for(source, config: {})
    analyze(source, config: config).diagnostics.map(&:rule)
  end

  def suppression_rules(source)
    rules_for(source).select { |rule| rule&.start_with?("suppression.") }
  end

  # The one shape every example below suppresses or fails to suppress; asserted here so a later `be_empty`
  # can only mean "the suppression worked", never "the fixture stopped firing".
  def unsuppressed
    %("x".no_method\n)
  end

  it "fires on the bare fixture every other example suppresses" do
    expect(rules_for(unsuppressed)).to include("call.undefined-method")
  end

  describe "line-level `# rigor:disable`" do
    it "suppresses the named rule on the comment's own line" do
      expect(rules_for(%("x".no_method # rigor:disable call.undefined-method\n))).to be_empty
    end

    # `expand_token` legacy-alias arm: the unprefixed spelling must resolve to the canonical id.
    it "accepts the legacy unprefixed alias as a token" do
      expect(rules_for(%("x".no_method # rigor:disable undefined-method\n))).to be_empty
    end

    # `expand_token` family arm: `call` expands to every `call.*` id rather than matching literally.
    it "accepts a family wildcard token" do
      expect(rules_for(%("x".no_method # rigor:disable call\n))).to be_empty
    end

    it "accepts the `all` wildcard" do
      expect(rules_for(%("x".no_method # rigor:disable all\n))).to be_empty
    end

    it "binds only the line the comment sits on" do
      source = <<~RUBY
        "x".no_method # rigor:disable call.undefined-method
        "y".also_missing
      RUBY
      expect(rules_for(source)).to contain_exactly("call.undefined-method")
    end
  end

  describe "file-level `# rigor:disable-file`" do
    it "suppresses the named rule on every line" do
      source = <<~RUBY
        # rigor:disable-file call.undefined-method
        "x".no_method
        "y".also_missing
      RUBY
      expect(rules_for(source)).to be_empty
    end

    it "suppresses every rule under the `all` wildcard" do
      source = <<~RUBY
        # rigor:disable-file all
        "x".no_method
        [1].rotate(1, 2)
      RUBY
      expect(rules_for(source)).to be_empty
    end

    # Pairs with the previous example: without the marker the same two lines both fire, so the `be_empty`
    # above is the marker's doing.
    it "leaves both shapes firing without the marker" do
      source = <<~RUBY
        "x".no_method
        [1].rotate(1, 2)
      RUBY
      expect(rules_for(source)).to contain_exactly("call.undefined-method", "call.wrong-arity")
    end

    it "does not suppress rules it did not name" do
      source = <<~RUBY
        # rigor:disable-file call.wrong-arity
        "x".no_method
      RUBY
      expect(rules_for(source)).to contain_exactly("call.undefined-method")
    end
  end

  # `expand_rule_tokens` over the project's `.rigor.yml` `disable:` list — the branch of `filter_suppressed`
  # no in-source marker can reach.
  describe "project-level `disable:`" do
    it "drops a canonical id listed in the configuration" do
      expect(rules_for(unsuppressed, config: { "disable" => ["call.undefined-method"] })).to be_empty
    end

    it "drops a legacy unprefixed alias listed in the configuration" do
      expect(rules_for(unsuppressed, config: { "disable" => ["undefined-method"] })).to be_empty
    end

    it "drops a whole family listed in the configuration" do
      expect(rules_for(unsuppressed, config: { "disable" => ["call"] })).to be_empty
    end

    it "keeps a diagnostic whose rule the list does not name" do
      expect(rules_for(unsuppressed, config: { "disable" => ["flow"] })).to contain_exactly("call.undefined-method")
    end
  end

  describe "marker surveillance" do
    it "warns that a typo'd token in a line marker resolves to nothing" do
      expect(suppression_rules(%("x".no_method # rigor:disable call.undefined-metod\n)))
        .to contain_exactly("suppression.unknown-rule")
    end

    it "warns on a typo'd token in a file marker" do
      expect(suppression_rules("# rigor:disable-file call.undefined-metod\n")).to contain_exactly(
        "suppression.unknown-rule"
      )
    end

    it "stays quiet when the token resolves" do
      expect(suppression_rules(%("x".no_method # rigor:disable call.undefined-method\n))).to be_empty
    end

    # `plugin.`-prefixed tokens are deliberately never flagged — plugin rule vocabularies load dynamically.
    it "never flags a `plugin.`-prefixed token" do
      expect(suppression_rules("x = 1 # rigor:disable plugin.anything.goes\n")).to be_empty
    end

    it "warns on a bare line marker that lists no rules" do
      expect(suppression_rules("x = 1 # rigor:disable\n")).to contain_exactly("suppression.empty")
    end

    it "warns on a bare file marker that lists no rules" do
      expect(suppression_rules("# rigor:disable-file\n")).to contain_exactly("suppression.empty")
    end

    it "warns on the RuboCop-reflex `disable-next-line` marker" do
      expect(suppression_rules(%("x".no_method # rigor:disable-next-line call.undefined-method\n)))
        .to contain_exactly("suppression.unknown-marker")
    end

    it "warns on a `rigor:enable` marker" do
      expect(suppression_rules("x = 1 # rigor:enable call\n")).to contain_exactly("suppression.unknown-marker")
    end

    # The surveillance rules flow through `filter_suppressed` like any other rule, and acknowledging one
    # never re-fires it (the token is known).
    it "is itself suppressible without regress" do
      source = %("x".no_method # rigor:disable call.undefined-metod, suppression.unknown-rule\n)
      expect(suppression_rules(source)).to be_empty
    end

    # Issue #321. The self-acknowledgement above is the INTENDED polarity — the surveillance rules are
    # ordinary tokens with no carve-out — but nothing pinned it over the whole diagnostic set, so a
    # refactor that reordered "compute surveillance diagnostics" against "apply suppression filtering"
    # could flip it with every example still green. The three below fix the polarity in place.
    #
    # They assert `rules_for`, not `suppression_rules`: the subset projection cannot tell "the
    # surveillance was acknowledged" apart from "the whole line got suppressed", and those are opposite
    # outcomes.
    it "lets a directive acknowledge the very warning it provokes" do
      source = "x = 1 # rigor:disable call.bogus-rule suppression.unknown-rule\n"
      expect(rules_for(source)).to be_empty
    end

    # The control for the example above: without the acknowledging token the same directive warns, so the
    # silence there is the self-ack and not a fixture that stopped firing.
    it "warns on the same directive when the acknowledgement is absent" do
      expect(rules_for("x = 1 # rigor:disable call.bogus-rule\n")).to contain_exactly("suppression.unknown-rule")
    end

    # The other half of the polarity: acknowledging the surveillance must not lend the bogus token any
    # suppressing power it did not have. The diagnostic the typo failed to name still fires.
    it "leaves the diagnostic the unknown token failed to name" do
      source = %("x".no_method # rigor:disable call.bogus-rule suppression.unknown-rule\n)
      expect(rules_for(source)).to contain_exactly("call.undefined-method")
    end
  end

  # Issue #306 — the anchoring. Each decline is paired with the genuinely-anchored sibling that still works,
  # so "nothing happened" can never be the fixture rather than the rule.
  describe "marker position within the comment" do
    it "ignores a file marker quoted inside prose" do
      source = <<~RUBY
        # Suppress the whole file with `# rigor:disable-file all` near the top.
        "x".no_method
      RUBY
      expect(rules_for(source)).to contain_exactly("call.undefined-method")
    end

    it "still honours the same file marker written at the start of its comment" do
      source = <<~RUBY
        # rigor:disable-file all
        "x".no_method
      RUBY
      expect(rules_for(source)).to be_empty
    end

    it "ignores a line marker quoted inside prose" do
      expect(rules_for(%("x".no_method # see `# rigor:disable call.undefined-method`\n)))
        .to contain_exactly("call.undefined-method")
    end

    it "warns about nothing when a typo'd marker is merely quoted" do
      source = <<~RUBY
        # A typo like `# rigor:disable call.undefined-metod` suppresses nothing.
        x = 1
      RUBY
      expect(rules_for(source)).to be_empty
    end

    # The anchored sibling of the previous example: the same token, this time actually a directive.
    it "warns when that typo'd marker opens its comment" do
      expect(suppression_rules("# rigor:disable call.undefined-metod\nx = 1\n"))
        .to contain_exactly("suppression.unknown-rule")
    end

    it "ignores an unknown marker quoted inside prose" do
      source = <<~RUBY
        # Rigor has no `# rigor:disable-next-line <rule>` form.
        x = 1
      RUBY
      expect(rules_for(source)).to be_empty
    end

    # A doc-tool `##` comment is not a directive: the second `#` is neither whitespace nor the marker word.
    it "ignores a doubled `##` marker" do
      source = <<~RUBY
        ## rigor:disable-file all
        "x".no_method
      RUBY
      expect(rules_for(source)).to contain_exactly("call.undefined-method")
    end

    # An `=begin`/`=end` comment token starts at `=begin`, so the anchor can never match inside one.
    it "ignores a marker inside an `=begin` block comment" do
      source = <<~RUBY
        =begin
        # rigor:disable-file all
        =end
        "x".no_method
      RUBY
      expect(rules_for(source)).to contain_exactly("call.undefined-method")
    end

    # The anchor constrains position, not spacing: `#` immediately followed by the marker word still works.
    it "accepts a marker with no space after the `#`" do
      expect(rules_for(%("x".no_method #rigor:disable call.undefined-method\n))).to be_empty
    end

    it "accepts a marker indented on its own line" do
      source = <<~RUBY
        def wrapper
          # rigor:disable-file call.undefined-method
          "x".no_method
        end
      RUBY
      expect(rules_for(source)).to be_empty
    end
  end

  # `filter_suppressed` refuses to drop a `rule == nil` diagnostic: a parse failure is not something an
  # author may silence away, so even the broadest marker leaves it standing.
  it "never suppresses a rule-less diagnostic" do
    source = <<~RUBY
      # rigor:disable-file all
      def broken(
    RUBY
    expect(analyze(source).diagnostics.map(&:rule)).to include(nil)
  end
end
