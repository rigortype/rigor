# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Issues #2437 and #2461 — a subclass is written against a project superclass only when the run writes that
# superclass's declaration too. Each example runs the generator and the writer over a fixture project; where the
# written `sig/` should load, it is checked with `RBS::Validator` and the definition builder over core plus the
# project's own signatures.
RSpec.describe Rigor::SigGen::Generator do
  let(:tmpdir) { Dir.mktmpdir }
  let(:base) { in_lib("class Base", "  def name = 1", "end") }
  let(:cdata) { in_lib("class Cdata < TextBase", "  def tag = \"cdata\"", "end") }

  after { FileUtils.remove_entry(tmpdir) }

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => ["lib"], "signature_paths" => ["sig"])
    )
  end

  # `lines` wrapped in `module Lib`, each indented one level.
  def in_lib(*lines)
    "module Lib\n#{lines.map { |line| "  #{line}\n" }.join}end\n"
  end

  def run_generator(files)
    files.each do |rel, contents|
      full = File.join(tmpdir, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.binwrite(full, contents)
    end
    Dir.chdir(tmpdir) do
      generator = described_class.new(configuration: configuration, paths: ["lib"])
      candidates = generator.run
      mapper = Rigor::SigGen::PathMapper.new(configuration: configuration, project_root: tmpdir)
      Rigor::SigGen::Writer.new(path_mapper: mapper).write_all(candidates)
      [candidates, generator]
    end
  end

  def sig(name)
    path = File.join(tmpdir, "sig/#{name}.rbs")
    File.exist?(path) ? File.read(path) : nil
  end

  def validation_errors
    loader = RBS::EnvironmentLoader.new
    loader.add(path: Pathname(File.join(tmpdir, "sig")))
    env = RBS::Environment.from_loader(loader).resolve_type_names
    builder = RBS::DefinitionBuilder.new(env: env)
    env.class_decls.keys.select { |name| name.to_s.start_with?("::Lib") }.flat_map do |name|
      %i[build_instance build_singleton].filter_map do |build|
        builder.public_send(build, name)
        nil
      rescue RBS::BaseError => e
        e.class
      end
    end
  end

  def expect_demoted(candidates, method_name)
    row = candidates.find { |c| c.method_name == method_name }
    expect([row.classification, row.skip_reason])
      .to eq([Rigor::SigGen::Classification::SKIPPED, :unresolvable_superclass])
  end

  describe "a project superclass whose every method is skipped (#2437)" do
    it "demotes the subclass instead of writing it against a superclass that never reaches disk" do
      candidates, generator = run_generator(
        "lib/base.rb" => base,
        "lib/text_base.rb" => in_lib("class TextBase < Base", "  def render(x) = x.whatever", "end"),
        "lib/cdata.rb" => cdata
      )

      expect(sig("text_base")).to be_nil
      expect(sig("cdata")).to be_nil
      expect(sig("base")).to include("class Base")
      expect_demoted(candidates, :tag)
      expect(generator.unresolvable_superclasses).to eq("Lib::Cdata" => "Lib::TextBase")
      expect(generator.source_declared_superclass?("Lib::TextBase")).to be(true)
      expect(validation_errors).to be_empty
    end

    # A guard (control): a superclass with one written method keeps its subclass.
    it "writes the subclass when the superclass has a method of its own written" do
      run_generator(
        "lib/base.rb" => base,
        "lib/text_base.rb" => in_lib("class TextBase < Base", "  def render(x) = x.whatever", "  def kind = 1",
                                     "end"),
        "lib/cdata.rb" => cdata
      )

      expect(sig("text_base")).to include("class TextBase < ::Lib::Base")
      expect(sig("cdata")).to include("class Cdata < ::Lib::TextBase")
      expect(validation_errors).to be_empty
    end

    it "counts the superclass as written when it is the wrapper of a written nested class" do
      run_generator(
        "lib/base.rb" => base,
        "lib/text_base.rb" => in_lib("class TextBase < Base", "  def render(x) = x.whatever", "  class Inner",
                                     "    def i = 1", "  end", "end"),
        "lib/cdata.rb" => cdata
      )

      expect(sig("text_base")).to include("class TextBase < ::Lib::Base\n    class Inner")
      expect(sig("cdata")).to include("class Cdata < ::Lib::TextBase")
      expect(validation_errors).to be_empty
    end

    it "demotes only the class below the unwritten link of a chain" do
      candidates, generator = run_generator(
        "lib/a.rb" => in_lib("class A", "  def a = 1", "end"),
        "lib/b.rb" => in_lib("class B < A", "  def b(x) = x.whatever", "end"),
        "lib/c.rb" => in_lib("class C < B", "  def c = 1", "end")
      )

      expect(sig("a")).to include("def a: () -> 1")
      expect(sig("c")).to be_nil
      expect_demoted(candidates, :c)
      expect(generator.unresolvable_superclasses).to eq("Lib::C" => "Lib::B")
      expect(validation_errors).to be_empty
    end
  end

  describe "a superclass shell on a target the writer refuses (#2461)" do
    let(:errors) { in_lib("class Error < StandardError; end", "class Thing", "  def x = 1", "end") }
    let(:subclass) { in_lib("class NotFound < Error", "  def code = 404", "end") }

    def expect_subclass_demoted(candidates, generator)
      expect(sig("sub")).to be_nil
      expect_demoted(candidates, :code)
      expect(generator.unresolvable_superclasses).to eq("Lib::NotFound" => "Lib::Error")
    end

    it "demotes the subclass when the shell's target does not parse" do
      broken = in_lib("class Thing", "  def y: () ->", "end")
      candidates, generator = run_generator("lib/errors.rb" => errors, "sig/errors.rbs" => broken,
                                            "lib/sub.rb" => subclass)

      expect(sig("errors")).to eq(broken)
      expect_subclass_demoted(candidates, generator)
    end

    it "demotes the subclass when the shell's target is not valid UTF-8" do
      mojibake = "module Lib\n  # \xFF\xFE\n  class Thing\n  end\nend\n".b
      candidates, generator = run_generator("lib/errors.rb" => errors, "sig/errors.rbs" => mojibake,
                                            "lib/sub.rb" => subclass)

      expect(File.binread(File.join(tmpdir, "sig/errors.rbs"))).to eq(mojibake)
      expect_subclass_demoted(candidates, generator)
    end

    # A guard (control): a parseable existing target is updated with the shell, and the subclass rests on it.
    it "writes the shell into a parseable existing target and keeps the subclass" do
      run_generator("lib/errors.rb" => errors, "sig/errors.rbs" => in_lib("class Thing", "end"),
                    "lib/sub.rb" => subclass)

      expect(sig("errors")).to include("class Error < ::StandardError", "def x: () -> 1")
      expect(sig("sub")).to include("class NotFound < ::Lib::Error")
      expect(validation_errors).to be_empty
    end
  end
end
