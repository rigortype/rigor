# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Rigor::SigGen::Writer do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def configuration(signature_paths: ["sig"])
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["lib"],
        "signature_paths" => signature_paths
      ).compact
    )
  end

  def writer(overwrite: false)
    mapper = Rigor::SigGen::PathMapper.new(configuration: configuration, project_root: tmpdir)
    described_class.new(path_mapper: mapper, overwrite: overwrite)
  end

  def candidate(method_name:, rbs:, classification: Rigor::SigGen::Classification::NEW_METHOD, class_name: "Foo",
                declared_return_rbs: nil)
    Rigor::SigGen::MethodCandidate.new(
      path: "lib/foo.rb",
      class_name: class_name,
      method_name: method_name,
      kind: :instance,
      classification: classification,
      rbs: rbs,
      declared_return_rbs: declared_return_rbs
    )
  end

  def write_target(content)
    target = File.join(tmpdir, "sig/foo.rbs")
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, content)
    target
  end

  describe "create new sig file" do
    it "writes a class declaration with the candidate methods when no target exists" do
      result = writer.write("lib/foo.rb", [candidate(method_name: :n, rbs: "def n: () -> Integer")])

      expect(result.action).to eq(:created)
      expect(File.read(result.target_path)).to eq("class Foo\n  def n: () -> Integer\nend\n")
    end

    it "groups multiple candidates per class declaration" do
      candidates = [
        candidate(method_name: :n, rbs: "def n: () -> Integer"),
        candidate(method_name: :s, rbs: "def s: () -> String")
      ]

      result = writer.write("lib/foo.rb", candidates)

      expect(File.read(result.target_path)).to include("def n: () -> Integer", "def s: () -> String")
    end
  end

  describe "merge into existing sig file" do
    it "inserts new methods before the existing class declaration's `end`" do
      write_target("class Foo\n  # keep me\n  def existing: () -> String\nend\n")

      writer.write("lib/foo.rb", [candidate(method_name: :added, rbs: "def added: () -> Integer")])
      output = File.read(File.join(tmpdir, "sig/foo.rbs"))

      expect(output).to include("# keep me")
      expect(output).to include("def existing: () -> String")
      expect(output).to match(/def added: \(\) -> Integer\nend/)
    end

    it "appends a new class declaration when the file does not declare it" do
      write_target("class Bar\n  def b: () -> Integer\nend\n")

      writer.write("lib/foo.rb", [candidate(method_name: :n, rbs: "def n: () -> Integer", class_name: "Foo")])
      output = File.read(File.join(tmpdir, "sig/foo.rbs"))

      expect(output).to include("class Bar")
      expect(output).to match(/class Foo\n  def n: \(\) -> Integer\nend/)
    end

    it "skips tighter-return candidates that conflict with user-authored RBS by default" do
      write_target("class Foo\n  def n: () -> Numeric\nend\n")
      tighter = candidate(
        method_name: :n, rbs: "def n: () -> Integer",
        classification: Rigor::SigGen::Classification::TIGHTER_RETURN,
        declared_return_rbs: "Numeric"
      )

      result = writer.write("lib/foo.rb", [tighter])

      expect(result.action).to eq(:noop)
      expect(result.skipped.map(&:last)).to eq([:user_authored])
      expect(File.read(File.join(tmpdir, "sig/foo.rbs"))).to include("def n: () -> Numeric")
    end
  end

  describe "with --overwrite for NEW_METHOD candidates that tighten existing `untyped`" do
    def new_method_candidate(method_name:, rbs:, kind: :instance, class_name: "Foo")
      Rigor::SigGen::MethodCandidate.new(
        path: "lib/foo.rb",
        class_name: class_name,
        method_name: method_name,
        kind: kind,
        classification: Rigor::SigGen::Classification::NEW_METHOD,
        rbs: rbs
      )
    end

    it "replaces an existing declaration when the new RBS has STRICTLY FEWER `untyped` tokens" do
      write_target("class Foo\n  def initialize: (path: untyped, ?opts: untyped) -> void\nend\n")
      stub = new_method_candidate(
        method_name: :initialize,
        rbs: "def initialize: (path: String, ?opts: Hash[String, untyped]) -> void"
      )

      result = writer(overwrite: true).write("lib/foo.rb", [stub])
      output = File.read(File.join(tmpdir, "sig/foo.rbs"))

      expect(result.action).to eq(:updated)
      expect(output).to include("(path: String, ?opts: Hash[String, untyped])")
    end

    it "skips when the new RBS has the same `untyped` count" do
      write_target("class Foo\n  def m: (untyped) -> Integer\nend\n")
      stub = new_method_candidate(
        method_name: :m,
        rbs: "def m: (Integer) -> untyped"
      )

      result = writer(overwrite: true).write("lib/foo.rb", [stub])

      expect(result.skipped.map(&:last)).to eq([:user_authored])
    end

    it "skips when the new RBS would INTRODUCE an `untyped` (no widening)" do
      write_target("class Foo\n  def m: (Integer) -> Integer\nend\n")
      stub = new_method_candidate(
        method_name: :m,
        rbs: "def m: (untyped) -> Integer"
      )

      result = writer(overwrite: true).write("lib/foo.rb", [stub])

      expect(result.skipped.map(&:last)).to eq([:user_authored])
    end

    it "does NOT replace without --overwrite even when the new RBS tightens untypeds" do
      write_target("class Foo\n  def m: (untyped) -> Integer\nend\n")
      stub = new_method_candidate(
        method_name: :m,
        rbs: "def m: (Integer) -> Integer"
      )

      result = writer(overwrite: false).write("lib/foo.rb", [stub])

      expect(result.skipped.map(&:last)).to eq([:user_authored])
    end
  end

  describe "with --overwrite" do
    it "replaces user-authored RBS for tighter-return candidates" do
      write_target("class Foo\n  def n: () -> Numeric\nend\n")
      tighter = candidate(
        method_name: :n, rbs: "def n: () -> Integer",
        classification: Rigor::SigGen::Classification::TIGHTER_RETURN,
        declared_return_rbs: "Numeric"
      )

      result = writer(overwrite: true).write("lib/foo.rb", [tighter])
      output = File.read(File.join(tmpdir, "sig/foo.rbs"))

      expect(result.action).to eq(:updated)
      expect(output).to include("def n: () -> Integer")
      expect(output).not_to include("Numeric")
    end

    it "preserves the original column indentation when replacing" do
      write_target("class Foo\n    def n: () -> Numeric\nend\n")
      tighter = candidate(
        method_name: :n, rbs: "def n: () -> Integer",
        classification: Rigor::SigGen::Classification::TIGHTER_RETURN
      )

      writer(overwrite: true).write("lib/foo.rb", [tighter])
      output = File.read(File.join(tmpdir, "sig/foo.rbs"))

      expect(output).to include("    def n: () -> Integer")
    end
  end

  describe "edge cases" do
    it "returns :noop when no emittable candidates are passed" do
      skipped_only = candidate(
        method_name: :n, rbs: nil,
        classification: Rigor::SigGen::Classification::SKIPPED
      )

      result = writer.write("lib/foo.rb", [skipped_only])

      expect(result.action).to eq(:noop)
    end
  end

  describe "singleton kind (slice 4)" do
    def singleton_candidate(method_name:, rbs:)
      Rigor::SigGen::MethodCandidate.new(
        path: "lib/foo.rb",
        class_name: "Foo",
        method_name: method_name,
        kind: :singleton,
        classification: Rigor::SigGen::Classification::NEW_METHOD,
        rbs: rbs
      )
    end

    it "inserts a singleton-side def without conflicting with a same-named instance method" do
      write_target("class Foo\n  def n: () -> Integer\nend\n")

      writer.write("lib/foo.rb", [singleton_candidate(method_name: :n, rbs: "def self.n: () -> Integer")])
      output = File.read(File.join(tmpdir, "sig/foo.rbs"))

      expect(output).to include("def n: () -> Integer")
      expect(output).to include("def self.n: () -> Integer")
    end

    it "treats an existing `def self.foo` as user-authored when classifications collide" do
      write_target("class Foo\n  def self.n: () -> String\nend\n")
      tighter = Rigor::SigGen::MethodCandidate.new(
        path: "lib/foo.rb", class_name: "Foo", method_name: :n, kind: :singleton,
        classification: Rigor::SigGen::Classification::TIGHTER_RETURN,
        rbs: "def self.n: () -> Integer", declared_return_rbs: "String"
      )

      result = writer.write("lib/foo.rb", [tighter])

      expect(result.skipped.map(&:last)).to eq([:user_authored])
    end
  end

  describe "attr_* member detection (slice 4)" do
    it "treats existing attr_reader as a same-name member and skips the generated reader" do
      write_target("class Foo\n  attr_reader name: String\nend\n")
      attr_reader = candidate(method_name: :name, rbs: "def name: () -> String")

      result = writer.write("lib/foo.rb", [attr_reader])

      expect(result.applied).to be_empty
      expect(result.skipped.map(&:last)).to eq([:user_authored])
    end

    it "treats existing attr_accessor as covering both reader and writer" do
      write_target("class Foo\n  attr_accessor age: Integer\nend\n")
      reader = candidate(method_name: :age, rbs: "def age: () -> Integer")
      writer_c = candidate(method_name: :age=, rbs: "def age=: (Integer) -> Integer")

      result = writer.write("lib/foo.rb", [reader, writer_c])

      expect(result.applied).to be_empty
      expect(result.skipped.size).to eq(2)
    end

    it "treats existing attr_writer as covering only the writer side" do
      write_target("class Foo\n  attr_writer count: Integer\nend\n")
      reader = candidate(method_name: :count, rbs: "def count: () -> Integer")
      writer_c = candidate(method_name: :count=, rbs: "def count=: (Integer) -> Integer")

      result = writer.write("lib/foo.rb", [reader, writer_c])

      expect(result.applied.map(&:method_name)).to eq([:count])
      expect(result.skipped.map { |c, _| c.method_name }).to eq([:count=])
    end
  end
end
