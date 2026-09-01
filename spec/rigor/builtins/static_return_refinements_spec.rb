# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Builtins::StaticReturnRefinements do
  describe ".lookup" do
    let(:expected_dir_type) do
      Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.non_empty_string,
        Rigor::Type::Combinator.constant_of(nil)
      )
    end

    it "returns `non-empty-string | nil` for Kernel#__dir__ (instance)" do
      type = described_class.lookup(
        owner_class_name: "Kernel",
        method_name: :__dir__,
        kind: :instance
      )
      expect(type).to eq(expected_dir_type)
    end

    it "returns `non-empty-string | nil` for Kernel.__dir__ (singleton)" do
      type = described_class.lookup(
        owner_class_name: "Kernel",
        method_name: :__dir__,
        kind: :singleton
      )
      expect(type).to eq(expected_dir_type)
    end

    # `IO.read` / `File.read` return nil only when a positional LENGTH is given (EOF); the
    # no-length whole-file idiom always returns a String — the upstream RBS's single
    # `-> String?` row fired possible-nil-receiver on working code (redmine's read_file_head).
    it "drops the nil for IO.read / File.read without a positional length" do
      path = Rigor::Type::Combinator.constant_of("x.txt")
      %w[IO File].each do |owner|
        type = described_class.lookup(
          owner_class_name: owner, method_name: :read, kind: :singleton, arg_types: [path]
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end
    end

    it "keeps a keyword-only trailing hash out of the length count (File.read(path, mode: 'rb'))" do
      path = Rigor::Type::Combinator.constant_of("x.txt")
      kwargs = Rigor::Type::Combinator.hash_shape_of(mode: Rigor::Type::Combinator.constant_of("rb"))
      type = described_class.lookup(
        owner_class_name: "File", method_name: :read, kind: :singleton, arg_types: [path, kwargs]
      )
      expect(type).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "declines IO.read WITH a positional length — nil is really possible at EOF" do
      path = Rigor::Type::Combinator.constant_of("x.txt")
      length = Rigor::Type::Combinator.constant_of(100)
      type = described_class.lookup(
        owner_class_name: "IO", method_name: :read, kind: :singleton, arg_types: [path, length]
      )
      expect(type).to be_nil
    end

    it "is nil for an unregistered method name" do
      type = described_class.lookup(
        owner_class_name: "Kernel",
        method_name: :nonexistent,
        kind: :instance
      )
      expect(type).to be_nil
    end

    it "is nil when the owner does not match a registered entry" do
      type = described_class.lookup(
        owner_class_name: "Comparable",
        method_name: :__dir__,
        kind: :instance
      )
      expect(type).to be_nil
    end

    it "is nil when the owner_class_name is nil" do
      type = described_class.lookup(
        owner_class_name: nil,
        method_name: :__dir__,
        kind: :instance
      )
      expect(type).to be_nil
    end
  end

  describe ".owners_for" do
    it "lists Kernel as the owner of __dir__" do
      expect(described_class.owners_for(:__dir__)).to eq(["Kernel"])
    end

    it "returns an empty array for an unregistered method" do
      expect(described_class.owners_for(:nonexistent)).to eq([])
    end

    it "accepts a String method name" do
      expect(described_class.owners_for("__dir__")).to eq(["Kernel"])
    end

    it "lists File as the owner of expand_path" do
      expect(described_class.owners_for(:expand_path)).to eq(["File"])
    end

    it "lists File as the owner of dirname" do
      expect(described_class.owners_for(:dirname)).to eq(["File"])
    end
  end

  describe "File class-side refinements" do
    let(:non_empty_string) { Rigor::Type::Combinator.non_empty_string }

    it "returns non-empty-string for File.expand_path (singleton)" do
      type = described_class.lookup(
        owner_class_name: "File", method_name: :expand_path, kind: :singleton
      )
      expect(type).to eq(non_empty_string)
    end

    it "returns non-empty-string for File.dirname (singleton)" do
      type = described_class.lookup(
        owner_class_name: "File", method_name: :dirname, kind: :singleton
      )
      expect(type).to eq(non_empty_string)
    end

    it "does NOT fire on the (non-existent) instance shape" do
      # File has no instance-side `expand_path` / `dirname`; the row is keyed `:singleton`, so an `:instance` lookup
      # must return nil rather than the singleton handler.
      expect(
        described_class.lookup(
          owner_class_name: "File", method_name: :expand_path, kind: :instance
        )
      ).to be_nil
    end

    it "does NOT refine File.basename (would be unsound — File.basename(\"\") == \"\")" do
      expect(
        described_class.lookup(
          owner_class_name: "File", method_name: :basename, kind: :singleton
        )
      ).to be_nil
    end
  end
end
