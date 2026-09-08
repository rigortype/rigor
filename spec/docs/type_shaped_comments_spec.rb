# frozen_string_literal: true

# Gate Rigor's own tree against "type-shaped comments": a type written in a comment is never checked
# by Rigor (types live in sig/, checked by `make check`, or are left to inference), so it can lie, and
# an AI agent reading the source has no way to tell a comment's claimed type from a checked one. See
# spec/support/type_shaped_comment_scanner.rb for the four rules (R1-R4) and their rationale — this
# file only wires the scanner to RSpec: unit examples pin each rule's judgment on inline fixtures
# (independent of the corpus), and corpus examples run it over lib/, plugins/*/lib/, examples/*/lib/.
#
# R1 is EXPECTED to fail on this branch: master carries ~1,100 bracketed YARD tags in lib/ alone, and
# clearing that corpus is separate work happening on another branch. This spec is the gate, not the
# fix — do not silence R1's corpus example to make it green.
require "spec_helper"

TYPE_SHAPED_COMMENTS_ROOT = File.expand_path("../..", __dir__)

# Scanned once at file load (not per example — this walks lib/, plugins/*/lib/, examples/*/lib/ with a
# full Prism parse each) and shared read-only across the corpus examples below.
TYPE_SHAPED_COMMENTS_TOTALS = TypeShapedCommentScanner.scan_tree(TYPE_SHAPED_COMMENTS_ROOT)

# A thousand-line corpus failure must still be readable; the total is always stated even when the
# listing is truncated.
TYPE_SHAPED_COMMENTS_LISTING_CAP = 200

module TypeShapedCommentsSpecHelpers
  def type_shaped_comments_failure(rule_label, violations)
    lines = violations.map(&:to_s)
    shown = lines.first(TYPE_SHAPED_COMMENTS_LISTING_CAP)
    suffix = lines.size > shown.size ? "\n  … #{lines.size - shown.size} more" : ""
    "#{rule_label}: #{lines.size} violation(s)\n  #{shown.join("\n  ")}#{suffix}"
  end

  def violations_for(rule, source, path: "fixture.rb")
    TypeShapedCommentScanner.public_send(rule, path, source)
  end
end

RSpec.describe "type-shaped comments (Rigor's own tree)" do
  include TypeShapedCommentsSpecHelpers

  describe "the scanner (inline fixtures, independent of the corpus)" do
    describe "R1 type-shaped tag" do
      it "flags a type bracket directly after the tag" do
        expect(violations_for(:r1_type_shaped_tag, "# @return [Integer]\ndef foo; end\n").size).to eq(1)
      end

      it "flags a type bracket after the parameter name" do
        source = "# @param name [String] the name\ndef foo(name); end\n"
        expect(violations_for(:r1_type_shaped_tag, source).size).to eq(1)
      end

      it "flags @option's bracket after its hash-parameter name" do
        source = "# @option opts [Symbol] :key description\ndef foo(opts); end\n"
        expect(violations_for(:r1_type_shaped_tag, source).size).to eq(1)
      end

      it "flags @raise's bracketed exception class" do
        source = "# @raise [ArgumentError] when invalid\ndef foo; end\n"
        expect(violations_for(:r1_type_shaped_tag, source).size).to eq(1)
      end

      it "does not flag a bare @param with no brackets" do
        source = "# @param name the description\ndef foo(name); end\n"
        expect(violations_for(:r1_type_shaped_tag, source)).to be_empty
      end

      it "does not flag a bare @raise naming the exception class in prose" do
        source = "# @raise ArgumentError when invalid\ndef foo; end\n"
        expect(violations_for(:r1_type_shaped_tag, source)).to be_empty
      end

      it "does not flag a bracket that only appears later in the description" do
        source = "# @return the value, e.g. [1, 2, 3]\ndef foo; end\n"
        expect(violations_for(:r1_type_shaped_tag, source)).to be_empty
      end

      it "does not flag a shape sketch after @return, which has no name slot" do
        source = "# @return `{ [path, name] => row }` keyed by pair\ndef foo; end\n"
        expect(violations_for(:r1_type_shaped_tag, source)).to be_empty
      end

      it "does not flag @!attribute's [r]/[w] access-mode marker" do
        source = "# @!attribute [r] name\nclass Foo; end\n"
        expect(violations_for(:r1_type_shaped_tag, source)).to be_empty
      end

      it "does not flag @see or a {Foo#bar} cross-reference" do
        source = "# @see {Foo#bar}\ndef foo; end\n"
        expect(violations_for(:r1_type_shaped_tag, source)).to be_empty
      end
    end

    describe "R2 inline rbs annotation" do
      it "flags a `# @rbs` block-form annotation" do
        source = "# @rbs (Integer) -> void\ndef foo(x); end\n"
        expect(violations_for(:r2_inline_rbs_annotation, source).size).to eq(1)
      end

      it "flags `# @rbs!` and `# @rbs skip`" do
        expect(violations_for(:r2_inline_rbs_annotation, "# @rbs! type foo = Integer\nx = 1\n").size).to eq(1)
        expect(violations_for(:r2_inline_rbs_annotation, "# @rbs skip\ndef foo; end\n").size).to eq(1)
      end

      it "flags a `#:` comment immediately followed by an RBS type" do
        source = "#: (Integer) -> void\ndef foo(x); end\n"
        expect(violations_for(:r2_inline_rbs_annotation, source).size).to eq(1)
      end

      it "does not flag RDoc directives (`#:nodoc:`, `#:call-seq:`)" do
        expect(violations_for(:r2_inline_rbs_annotation, "#:nodoc:\ndef foo; end\n")).to be_empty
        source = "#:call-seq:\n#:  foo(x)\ndef foo(x); end\n"
        expect(violations_for(:r2_inline_rbs_annotation, source)).to be_empty
      end

      it "never matches text that only looks like an annotation inside a string literal" do
        # Regression for lib/rigor/analysis/rule_catalog.rb, whose diagnostic message strings embed the
        # literal text "# @rbs" — Prism never emits a Comment for it, so the scanner (which only ever
        # looks at real Comment nodes) must not either.
        source = %(MESSAGE = "the annotation is written as an rbs-inline \\"# @rbs %a{...}\\" comment"\n)
        expect(violations_for(:r2_inline_rbs_annotation, source)).to be_empty
      end
    end

    describe "R3 stale parameter name" do
      it "flags a @param naming something that is not a parameter of the def below it" do
        source = "# @param name description\ndef foo(bogus); end\n"
        expect(violations_for(:r3_stale_parameter_name, source).size).to eq(1)
      end

      it "does not flag a @param that matches the def's actual parameter" do
        source = "# @param name description\ndef foo(name); end\n"
        expect(violations_for(:r3_stale_parameter_name, source)).to be_empty
      end

      it "matches a keyword parameter's bare name (@param/@option, no trailing colon required)" do
        source = "# @option opts description\ndef foo(opts: {}); end\n"
        expect(violations_for(:r3_stale_parameter_name, source)).to be_empty
      end

      it "strips a splat/double-splat/block sigil before comparing" do
        expect(violations_for(:r3_stale_parameter_name, "# @param args description\ndef foo(*args); end\n"))
          .to be_empty
        expect(violations_for(:r3_stale_parameter_name, "# @param blk description\ndef foo(&blk); end\n"))
          .to be_empty
      end

      it "does not flag a name absorbed by a **rest capture" do
        # lib/rigor/type/hash_shape.rb's real shape: individually-documented keyword options folded
        # through **keywords rather than named parameters.
        source = "# @param pairs description\n# @param required_keys description\ndef foo(pairs, **keywords); end\n"
        expect(violations_for(:r3_stale_parameter_name, source)).to be_empty
      end

      it "skips a doc block separated from the def by a blank line" do
        source = "# @param bogus stale\n\ndef foo(real); end\n"
        expect(violations_for(:r3_stale_parameter_name, source)).to be_empty
      end

      it "skips a @param block above something that is not a def" do
        source = "# @param bogus stale\nattr_reader :real\n"
        expect(violations_for(:r3_stale_parameter_name, source)).to be_empty
      end

      it "flags a stale name on a def nested inside another def" do
        source = "def outer\n  # @param bogus stale\n  def inner(real)\n  end\nend\n"
        expect(violations_for(:r3_stale_parameter_name, source).size).to eq(1)
      end
    end

    describe "R4 stale forward reference" do
      it "flags an explicit numbered-slice forward reference" do
        expect(violations_for(:r4_stale_forward_reference, "# Slice 3 will add this.\ndef foo; end\n").size)
          .to eq(1)
        expect(violations_for(:r4_stale_forward_reference, "# deferred to Slice 5\ndef foo; end\n").size)
          .to eq(1)
      end

      it "does not flag ordinary forward-looking prose" do
        source = "# we will refactor this eventually\ndef foo; end\n"
        expect(violations_for(:r4_stale_forward_reference, source)).to be_empty
      end
    end

    describe "R5 missing delimiter" do
      it "flags a name that runs straight into its description" do
        source = "# @param format the output format\ndef foo(format); end\n"
        expect(violations_for(:r5_missing_delimiter, source).size).to eq(1)
      end

      it "accepts the em dash after the name, and a bare name whose description continues below" do
        source = "# @param format — the output format\n# @param width —\n#   the wrap column\n" \
                 "def foo(format, width); end\n"
        expect(violations_for(:r5_missing_delimiter, source)).to be_empty
      end

      it "accepts a bare name with nothing after it, since there is nothing to delimit" do
        source = "# @raise AnalyzerCrashed\ndef foo; end\n"
        expect(violations_for(:r5_missing_delimiter, source)).to be_empty
      end

      it "checks @raise's exception class the same way, and leaves @return alone" do
        source = "# @raise ArgumentError when amount is zero\n# @return the balance\ndef foo; end\n"
        excerpts = violations_for(:r5_missing_delimiter, source).map(&:excerpt)
        expect(excerpts).to eq(["# @raise ArgumentError when amount is zero"])
      end

      it "does not accept a double hyphen or a colon as the delimiter" do
        source = "# @param format -- the output format\n# @param width: the wrap column\ndef foo(format, width:); end\n"
        expect(violations_for(:r5_missing_delimiter, source).size).to eq(2)
      end
    end
  end

  describe "the corpus" do
    it "scans a non-empty file set (guards the globs against a tree reshuffle)" do
      scanned = TypeShapedCommentScanner.scan_paths(TYPE_SHAPED_COMMENTS_ROOT)
      expect(scanned).not_to be_empty
      expect(scanned.grep(%r{/lib/})).not_to be_empty
      expect(scanned.grep(%r{plugins/.*/lib/})).not_to be_empty
      expect(scanned.grep(%r{/spec/})).not_to be_empty
      expect(scanned.grep(%r{/fixtures/})).to be_empty
      expect(scanned.grep(%r{/vendor/})).to be_empty
    end

    # EXPECTED RED on this branch (see file header) — the corpus fix is separate work.
    it "carries no type-shaped YARD tag (R1)" do
      violations = TYPE_SHAPED_COMMENTS_TOTALS.fetch(:r1)
      expect(violations).to be_empty, type_shaped_comments_failure("R1 type-shaped tag", violations)
    end

    it "carries no inline rbs-inline annotation (R2)" do
      violations = TYPE_SHAPED_COMMENTS_TOTALS.fetch(:r2)
      expect(violations).to be_empty, type_shaped_comments_failure("R2 inline rbs annotation", violations)
    end

    it "carries no stale @param/@option name (R3)" do
      violations = TYPE_SHAPED_COMMENTS_TOTALS.fetch(:r3)
      expect(violations).to be_empty, type_shaped_comments_failure("R3 stale parameter name", violations)
    end

    it "carries no stale numbered-slice forward reference (R4)" do
      violations = TYPE_SHAPED_COMMENTS_TOTALS.fetch(:r4)
      expect(violations).to be_empty, type_shaped_comments_failure("R4 stale forward reference", violations)
    end

    it "delimits every named tag with an em dash (R5)" do
      violations = TYPE_SHAPED_COMMENTS_TOTALS.fetch(:r5)
      expect(violations).to be_empty, type_shaped_comments_failure("R5 missing delimiter", violations)
    end
  end
end
