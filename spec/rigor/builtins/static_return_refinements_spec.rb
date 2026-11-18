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

  # Issue #3326 — a slice whose start is statically 0 (a literal `0`, or a beginless range) is never past the end,
  # so `Array#[]` / `#slice` and `String#[]` / `#slice` answer the receiver's type without the RBS-declared `nil`.
  # Ruby 4.0.5: `[][0...-1]` => [], `[][..2]` => [], `[1][0, -1]` => nil, `[][1..]` => nil, `[][-1..]` => nil,
  # `""[0..]` => "", `""[1..]` => nil. The rule reads the argument NODE (a `0..i` range types as `Range[Integer]`
  # and has lost its start), so every example types a parsed snippet through `ScopeIndexer`, which is what sees a
  # `using` and a class body's `def`.
  describe "zero-start slices (issue #3326)" do
    seed = <<~RUBY
      a = ARGV
      s = ENV.fetch("X")
      i = ARGV.size
      j = Integer(ARGV[0])
      z = 0
      t = [1, ARGV.size]
      e = []
      u = ARGV.empty? ? ARGV : ARGV.map(&:size)
      m = ARGV.empty? ? ARGV : ARGV.first.to_s
      w = ARGV.first ? ARGV : []
      n = ARGV.empty? ? nil : ARGV
      ne = ARGV.empty? ? ["x"] : ARGV
    RUBY

    define_method(:type_after_seed) do |expression, environment: Rigor::Environment.default, prelude: ""|
      program = Prism.parse("#{prelude}#{seed}#{expression}\n").value
      index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty(environment: environment))
      last = program.statements.body.last
      index[last].type_of(last).describe(:short)
    end

    {
      "a[0...-1]" => "Array[String]",
      "a[0..]" => "Array[String]",
      "a[0...]" => "Array[String]",
      "a[0..-5]" => "Array[String]",
      "a[0..i]" => "Array[String]",
      "a[0...j]" => "Array[String]",
      "a[-0..]" => "Array[String]",
      "a[..2]" => "Array[String]",
      "a[...0]" => "Array[String]",
      "a[..j]" => "Array[String]",
      "a.slice(0..)" => "Array[String]",
      "a.slice(..j)" => "Array[String]",
      "a[0, 2]" => "Array[String]",
      "a[0, i]" => "Array[String]",
      "a[z..]" => "Array[String]",
      "s[0..]" => "String",
      "s[0...-1]" => "String",
      "s[..j]" => "String",
      "s.slice(0..i)" => "String",
      "s[0, 2]" => "String",
      "t[0..i]" => "Array[1 | non-negative-int]",
      "e[0..i]" => "Array[Dynamic[top]]",
      "u[0..]" => "Array[String] | Array[non-negative-int]",
      "m[0...-1]" => "Array[String] | String",
      "w[0...-1]" => "Array[Dynamic[top]] | Array[String]",
      "ne[0..]" => "Array[\"x\"] | Array[String]"
    }.each do |expression, expected|
      it "drops the nil of #{expression}" do
        expect(type_after_seed(expression)).to eq(expected)
      end
    end

    # Every other start keeps today's (declared) answer; so does a length that may be negative, a single index,
    # and an argument the node check cannot see through.
    {
      "a[1..]" => "Array[String]?",
      "a[3..]" => "Array[String]?",
      "a[-1..]" => "Array[String]?",
      "a[i..]" => "Array[String]?",
      "a[j..i]" => "Array[String]?",
      "a[1, 2]" => "Array[String]?",
      "a[0, j]" => "Array[String]?",
      "a[0, -1]" => "Array[String]?",
      "a[0]" => "String",
      "a[i]" => "String",
      "a[(0..i)]" => "Array[String]?",
      "a.public_send(:slice, 0..i)" => "Array[String]?",
      "s[1..]" => "String?",
      "s[-1..]" => "String?",
      "s[1, 2]" => "String?",
      "t[1..i]" => "Array[1 | non-negative-int]?",
      "u[1..]" => "Array[String] | Array[non-negative-int] | nil",
      "w[1..]" => "Array[Dynamic[top]] | Array[String] | nil",
      "n&.[](0..)" => "Array[String]?"
    }.each do |expression, expected|
      it "keeps the declared answer of #{expression}" do
        expect(type_after_seed(expression)).to eq(expected)
      end
    end

    it "leaves a Tuple read ShapeDispatch answers exactly as it was" do
      expect([type_after_seed("t[0..]"), type_after_seed("t[1..]"), type_after_seed("e[0...-1]")])
        .to eq(["[1, non-negative-int]", "[non-negative-int]", "[]"])
    end

    # The table is keyed on the exact class name, so a subclass that overrides the read answers from its own `def`.
    it "leaves a subclass of Array that overrides [] to its own method" do
      prelude = "class NilArr < Array\n  def [](*) = nil\nend\n"
      expect(type_after_seed("NilArr.new[0..]", prelude: prelude)).to eq("nil")
    end

    it "answers a refined [] from the refine body, ahead of the table" do
      prelude = "module NilSlice\n  refine Array do\n    def [](*) = nil\n  end\nend\nusing NilSlice\n"
      expect([type_after_seed("a[0..]", prelude: prelude), type_after_seed("a.slice(0..)", prelude: prelude)])
        .to eq(["nil", "Array[String]"])
    end

    it "keeps the declared answer when a pre_eval patch redefines the read (ADR-17)" do
      entries = [["Array", :[]], ["String", :slice]].map do |class_name, method_name|
        Rigor::Inference::ProjectPatchedMethods::Entry.new(
          class_name: class_name, method_name: method_name, kind: :instance,
          source_path: "ext/core_ext.rb", source_line: 1
        )
      end
      environment = Rigor::Environment.for_project(
        project_patched_methods: Rigor::Inference::ProjectPatchedMethods.new(entries: entries)
      )
      answers = %w[a[0..] a.slice(0..) s[0..] s.slice(0..)].map { |expr| type_after_seed(expr, environment: environment) }
      expect(answers).to eq(["Array[String]?", "Array[String]", "String", "String?"])
    end
  end
end
