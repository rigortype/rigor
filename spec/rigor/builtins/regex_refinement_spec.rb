# frozen_string_literal: true

require "spec_helper"

require "rigor/builtins/regex_refinement"

RSpec.describe Rigor::Builtins::RegexRefinement do
  describe ".for_capture_body" do
    context "with `\\d`-headed bodies" do
      it "maps `\\d+` to decimal-int-string" do
        expect(described_class.for_capture_body('\d+'))
          .to eq(Rigor::Type::Combinator.decimal_int_string)
      end

      it "maps `\\d{4}` to decimal-int-string" do
        expect(described_class.for_capture_body('\d{4}'))
          .to eq(Rigor::Type::Combinator.decimal_int_string)
      end

      it "maps `\\d{2,4}` to decimal-int-string" do
        expect(described_class.for_capture_body('\d{2,4}'))
          .to eq(Rigor::Type::Combinator.decimal_int_string)
      end
    end

    context "with `\\h`- and explicit-class hex bodies (#1004: non-empty-string, NEVER hex-int-string)" do
      # `hex-int-string`'s predicate REQUIRES the `0x` / `0X` prefix (`refined.rb`). A bare hex-digit
      # class like `[0-9a-fA-F]+` matches "ff", which has no prefix at all — mapping it to
      # `hex-int-string` was false of the value it claims to describe. `non-empty-string` is the sound
      # floor: the `+` / bounded quantifier already guarantees a non-empty match.
      it "maps `\\h+` to non-empty-string" do
        expect(described_class.for_capture_body('\h+'))
          .to eq(Rigor::Type::Combinator.non_empty_string)
      end

      it "maps `[0-9a-fA-F]+` to non-empty-string" do
        expect(described_class.for_capture_body("[0-9a-fA-F]+"))
          .to eq(Rigor::Type::Combinator.non_empty_string)
      end

      it "maps `[0-9a-f]+` and `[0-9A-F]+` to non-empty-string" do
        expect(described_class.for_capture_body("[0-9a-f]+"))
          .to eq(Rigor::Type::Combinator.non_empty_string)
        expect(described_class.for_capture_body("[0-9A-F]+"))
          .to eq(Rigor::Type::Combinator.non_empty_string)
      end

      it "maps `\\h{8}` to non-empty-string" do
        expect(described_class.for_capture_body('\h{8}'))
          .to eq(Rigor::Type::Combinator.non_empty_string)
      end
    end

    context "with `[0-7]`-class octal bodies (#1004: non-empty-string, NEVER octal-int-string)" do
      # Same unsoundness for the `0o` / leading-`0` prefix `octal-int-string` requires: "17" matches
      # `[0-7]+` but has no such prefix.
      it "maps `[0-7]+` to non-empty-string" do
        expect(described_class.for_capture_body("[0-7]+"))
          .to eq(Rigor::Type::Combinator.non_empty_string)
      end

      it "maps `[0-7]{3}` to non-empty-string" do
        expect(described_class.for_capture_body("[0-7]{3}"))
          .to eq(Rigor::Type::Combinator.non_empty_string)
      end
    end

    context "with `[a-z]` / `[A-Z]` letter-class bodies" do
      it "maps `[a-z]+` to lowercase-string" do
        expect(described_class.for_capture_body("[a-z]+"))
          .to eq(Rigor::Type::Combinator.lowercase_string)
      end

      it "maps `[A-Z]+` to uppercase-string" do
        expect(described_class.for_capture_body("[A-Z]+"))
          .to eq(Rigor::Type::Combinator.uppercase_string)
      end

      it "maps `[a-z]{1,4}` to lowercase-string" do
        expect(described_class.for_capture_body("[a-z]{1,4}"))
          .to eq(Rigor::Type::Combinator.lowercase_string)
      end
    end

    context "with the POSIX `[[:digit:]]` body" do
      it "maps `[[:digit:]]+` to numeric-string" do
        expect(described_class.for_capture_body("[[:digit:]]+"))
          .to eq(Rigor::Type::Combinator.numeric_string)
      end

      it "maps `[[:digit:]]{6}` to numeric-string" do
        expect(described_class.for_capture_body("[[:digit:]]{6}"))
          .to eq(Rigor::Type::Combinator.numeric_string)
      end
    end

    context "with rejected forms (return nil so the caller falls back to plain String)" do
      it "rejects empty / nil bodies" do
        expect(described_class.for_capture_body("")).to be_nil
        expect(described_class.for_capture_body(nil)).to be_nil
      end

      it "rejects `*` and `?` quantifiers (admit the empty string)" do
        expect(described_class.for_capture_body('\d*')).to be_nil
        expect(described_class.for_capture_body('\d?')).to be_nil
        expect(described_class.for_capture_body("[a-z]*")).to be_nil
      end

      it "rejects `{0,N}` quantifier (zero-length match allowed)" do
        expect(described_class.for_capture_body('\d{0,4}')).to be_nil
        expect(described_class.for_capture_body("[a-z]{0,4}")).to be_nil
      end

      it "rejects inverted bounds `{N,M}` with N > M" do
        expect(described_class.for_capture_body('\d{5,3}')).to be_nil
      end

      it "rejects partial matches (anything outside the curated table)" do
        expect(described_class.for_capture_body('\d+\s*')).to be_nil
        expect(described_class.for_capture_body("[a-z0-9]+")).to be_nil
        expect(described_class.for_capture_body("[A-Za-z]+")).to be_nil
        expect(described_class.for_capture_body("foo")).to be_nil
      end

      it "rejects anchored forms (anchors belong to the outer regex, not the capture body)" do
        expect(described_class.for_capture_body('\A\d+\z')).to be_nil
      end
    end
  end

  describe ".for_whole_pattern" do
    context "with fully `\\A…\\z`-anchored single-char-class sources (SOUND)" do
      it "maps `\\A\\d+\\z` and `\\A[0-9]+\\z` to decimal-int-string" do
        expect(described_class.for_whole_pattern('\A\d+\z'))
          .to eq(Rigor::Type::Combinator.decimal_int_string)
        expect(described_class.for_whole_pattern('\A[0-9]+\z'))
          .to eq(Rigor::Type::Combinator.decimal_int_string)
      end

      it "maps the bounded `\\A\\d{4}\\z` to decimal-int-string" do
        expect(described_class.for_whole_pattern('\A\d{4}\z'))
          .to eq(Rigor::Type::Combinator.decimal_int_string)
      end

      it "maps `\\A[[:digit:]]+\\z` to numeric-string" do
        expect(described_class.for_whole_pattern('\A[[:digit:]]+\z'))
          .to eq(Rigor::Type::Combinator.numeric_string)
      end

      it "maps `\\A\\h+\\z` and `\\A[0-9a-fA-F]+\\z` to non-empty-string, NEVER hex-int-string (#1004)" do
        expect(described_class.for_whole_pattern('\A\h+\z'))
          .to eq(Rigor::Type::Combinator.non_empty_string)
        expect(described_class.for_whole_pattern('\A[0-9a-fA-F]+\z'))
          .to eq(Rigor::Type::Combinator.non_empty_string)
      end

      it "maps `\\A[0-7]+\\z` to non-empty-string, NEVER octal-int-string (#1004)" do
        expect(described_class.for_whole_pattern('\A[0-7]+\z'))
          .to eq(Rigor::Type::Combinator.non_empty_string)
      end

      it "maps `\\A[a-z]+\\z` / `\\A[A-Z]+\\z` to lower/uppercase-string" do
        expect(described_class.for_whole_pattern('\A[a-z]+\z'))
          .to eq(Rigor::Type::Combinator.lowercase_string)
        expect(described_class.for_whole_pattern('\A[A-Z]+\z'))
          .to eq(Rigor::Type::Combinator.uppercase_string)
      end
    end

    context "with sources the whole-receiver regime MUST NOT narrow" do
      it "rejects a bare / unanchored source (matches a substring)" do
        expect(described_class.for_whole_pattern('\d+')).to be_nil
      end

      it "rejects one-sided anchoring (`\\A\\d+` or `\\d+\\z`)" do
        expect(described_class.for_whole_pattern('\A\d+')).to be_nil
        expect(described_class.for_whole_pattern('\d+\z')).to be_nil
      end

      it "rejects the capital `\\Z` end anchor (admits a trailing newline)" do
        expect(described_class.for_whole_pattern('\A\d+\Z')).to be_nil
      end

      it "rejects line anchors `^`/`$`" do
        expect(described_class.for_whole_pattern('^\d+$')).to be_nil
      end

      it "rejects an unrecognised inner body (`\\A\\w+\\z`)" do
        expect(described_class.for_whole_pattern('\A\w+\z')).to be_nil
      end

      it "rejects empty-admitting quantifiers between anchors" do
        expect(described_class.for_whole_pattern('\A\d*\z')).to be_nil
        expect(described_class.for_whole_pattern('\A\d?\z')).to be_nil
      end

      it "rejects the empty anchored source `\\A\\z` and a nil source" do
        expect(described_class.for_whole_pattern('\A\z')).to be_nil
        expect(described_class.for_whole_pattern(nil)).to be_nil
      end
    end
  end

  describe "RULES table / predicate soundness (#1004)" do
    # Every RULES row claims its refinement describes what its regex body matches. This runs each
    # body's OWN regex semantics (independent of the RULES table — Ruby's `Regexp` engine, not our
    # hand-picked positive examples) against a real sample, confirms the sample genuinely is a match,
    # and then asserts the mapped refinement's real predicate/acceptance accepts that same sample. A
    # hand-picked example that only exercises the prefixed literal case (`"0xff"`) would not have
    # caught #1004 — the bug was specifically that a bare, prefix-free match ("ff") reaches a
    # refinement whose predicate requires the prefix.
    def refinement_accepts?(refinement, value)
      constant = Rigor::Type::Combinator.constant_of(value)
      refinement.respond_to?(:matches?) ? refinement.matches?(value) : refinement.accepts(constant).yes?
    end

    sample_by_body = {
      '\d+' => "42",
      "[0-9]+" => "07",
      '\h+' => "ff",
      "[0-9a-fA-F]+" => "1F",
      "[0-9a-f]+" => "0a",
      "[0-9A-F]+" => "0A",
      "[0-7]+" => "17",
      "[a-z]+" => "abc",
      "[A-Z]+" => "ABC",
      "[[:digit:]]+" => "007"
    }

    sample_by_body.each do |body, sample|
      it "the refinement for `#{body}` accepts a real match of its own regex (#{sample.inspect})" do
        expect(sample).to match(/\A#{body}\z/), "sample #{sample.inspect} is not itself a match of /#{body}/"

        refinement = described_class.for_capture_body(body)
        expect(refinement).not_to be_nil

        expect(refinement_accepts?(refinement, sample)).to be(true),
                                                           "for_capture_body(#{body.inspect}) => " \
                                                           "#{refinement.describe}, which rejects " \
                                                           "#{sample.inspect} even though /#{body}/ matches it"
      end
    end
  end
end
