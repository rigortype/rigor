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

    context "with `\\h`- and explicit-class hex bodies" do
      it "maps `\\h+` to hex-int-string" do
        expect(described_class.for_capture_body('\h+'))
          .to eq(Rigor::Type::Combinator.hex_int_string)
      end

      it "maps `[0-9a-fA-F]+` to hex-int-string" do
        expect(described_class.for_capture_body("[0-9a-fA-F]+"))
          .to eq(Rigor::Type::Combinator.hex_int_string)
      end

      it "maps `[0-9a-f]+` and `[0-9A-F]+` to hex-int-string" do
        expect(described_class.for_capture_body("[0-9a-f]+"))
          .to eq(Rigor::Type::Combinator.hex_int_string)
        expect(described_class.for_capture_body("[0-9A-F]+"))
          .to eq(Rigor::Type::Combinator.hex_int_string)
      end

      it "maps `\\h{8}` to hex-int-string" do
        expect(described_class.for_capture_body('\h{8}'))
          .to eq(Rigor::Type::Combinator.hex_int_string)
      end
    end

    context "with `[0-7]`-class octal bodies" do
      it "maps `[0-7]+` to octal-int-string" do
        expect(described_class.for_capture_body("[0-7]+"))
          .to eq(Rigor::Type::Combinator.octal_int_string)
      end

      it "maps `[0-7]{3}` to octal-int-string" do
        expect(described_class.for_capture_body("[0-7]{3}"))
          .to eq(Rigor::Type::Combinator.octal_int_string)
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

      it "maps `\\A\\h+\\z` and `\\A[0-9a-fA-F]+\\z` to hex-int-string" do
        expect(described_class.for_whole_pattern('\A\h+\z'))
          .to eq(Rigor::Type::Combinator.hex_int_string)
        expect(described_class.for_whole_pattern('\A[0-9a-fA-F]+\z'))
          .to eq(Rigor::Type::Combinator.hex_int_string)
      end

      it "maps `\\A[0-7]+\\z` to octal-int-string" do
        expect(described_class.for_whole_pattern('\A[0-7]+\z'))
          .to eq(Rigor::Type::Combinator.octal_int_string)
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
end
