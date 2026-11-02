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

  def write_files(files)
    files.each do |rel, contents|
      full = File.join(tmpdir, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.binwrite(full, contents)
    end
  end

  def run_generator(files)
    write_files(files)
    Dir.chdir(tmpdir) do
      generator = described_class.new(configuration: configuration, paths: ["lib"], target_writer: target_writer)
      candidates = generator.run
      Rigor::SigGen::Writer.new(path_mapper: path_mapper).write_all(candidates)
      [candidates, generator]
    end
  end

  # What `CLI::SigGenCommand#build_writer` builds for a `--write` run from the current directory.
  def path_mapper
    Rigor::SigGen::PathMapper.new(
      configuration: configuration,
      layout_index: Rigor::SigGen::LayoutIndex.new(signature_paths: configuration.signature_paths)
    )
  end

  def target_writer
    Rigor::SigGen::Writer.new(path_mapper: path_mapper, dry_run: true)
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
      expect(generator.unresolvable_superclass_report("Lib::TextBase")).to eq([:project, "Lib::TextBase"])
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

    # Run from another directory, every target maps outside that directory's `sig/`, which the writer refuses.
    it "demotes the subclass when the shell's target is outside the sig root" do
      write_files("lib/errors.rb" => errors, "lib/sub.rb" => subclass)
      elsewhere = Dir.mktmpdir
      generator = Dir.chdir(elsewhere) do
        described_class.new(configuration: configuration, paths: [File.join(tmpdir, "lib")],
                            target_writer: target_writer).tap(&:run)
      ensure
        FileUtils.remove_entry(elsewhere)
      end

      expect(generator.unresolvable_superclasses).to eq("Lib::NotFound" => "Lib::Error")
    end

    it "demotes the subclass when the shell's target cannot be read" do
      skip "root reads a mode-000 file, so the target stays readable" if Process.uid.zero?

      write_files("lib/errors.rb" => errors, "sig/errors.rbs" => in_lib("class Thing", "end"), "lib/sub.rb" => subclass)
      target = File.join(tmpdir, "sig/errors.rbs")
      File.chmod(0o000, target)
      generator = Dir.chdir(tmpdir) do
        described_class.new(configuration: configuration, paths: ["lib"], target_writer: target_writer).tap(&:run)
      ensure
        File.chmod(0o644, target)
      end

      expect(generator.unresolvable_superclasses).to eq("Lib::NotFound" => "Lib::Error")
    end

    # Print, diff and JSON runs pass no writer, and their output must not depend on the target files or the
    # working directory: the class counts as written on its candidate alone, as before #2461.
    it "keeps the subclass when no target writer is given, whatever the target" do
      write_files("lib/errors.rb" => errors, "sig/errors.rbs" => in_lib("class Thing", "  def y: () ->", "end"),
                  "lib/sub.rb" => subclass)
      generator = Dir.chdir(tmpdir) { described_class.new(configuration: configuration, paths: ["lib"]).tap(&:run) }

      expect(generator.unresolvable_superclasses).to be_empty
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

  # Issue #2579 — a superclass token that names the class being opened. Ruby evaluates the superclass expression
  # before the new constant exists, so `class B < B` inside `module C` inside `module A` reads the enclosing `A::B`,
  # not the `A::C::B` it declares. The header was written `class A::C::B < A::C::B`, which RBS rejects as a
  # recursive ancestor, so the declaration was dropped with the whole class unsigned.
  describe "a superclass that names the class being opened (#2579)" do
    it "resolves a nested superclass of the same short name to the outer class" do
      run_generator(
        "lib/nested.rb" => <<~RUBY
          module Lib
            class B
              def hi = 1
            end
            module C
              class B < B
                def ho = 2
              end
            end
          end
        RUBY
      )

      expect(sig("nested")).to include("class B < ::Lib::B\n")
      expect(sig("nested")).not_to include("< ::Lib::C::B")
      expect(validation_errors).to be_empty
    end

    it "resolves a superclass named like a class of the outer namespace (rails shape)" do
      run_generator(
        "lib/schema.rb" => <<~RUBY
          module Lib
            class SchemaDumper
              def dump = "x"
            end
            module ConnectionAdapters
              class SchemaDumper < SchemaDumper
                def adapter = "pg"
              end
            end
          end
        RUBY
      )

      expect(sig("schema")).to include("class SchemaDumper < ::Lib::SchemaDumper\n")
      expect(sig("schema")).not_to include("< ::Lib::ConnectionAdapters::SchemaDumper")
      expect(validation_errors).to be_empty
    end

    # The token is the class's own name at the top level, so no candidate answers and the superclass is dropped
    # rather than written as a self-reference.
    it "drops a top-level superclass that is the class's own name" do
      run_generator("lib/lone.rb" => "class Lone < Lone\n  def x = 1\nend\n")

      expect(sig("lone")).to include("class Lone\n")
      expect(sig("lone")).not_to include("< ")
      expect(validation_errors).to be_empty
    end

    # A different innermost class still wins: `B` inside `Lib::C::D` names `Lib::C::B`, not the class being opened.
    it "resolves a superclass to a nearer class of another name than the one being opened" do
      run_generator(
        "lib/deep.rb" => <<~RUBY
          module Lib
            class B
              def hi = 1
            end
            module C
              class B
                def mid = 2
              end
              module D
                class B < B
                  def ho = 3
                end
              end
            end
          end
        RUBY
      )

      expect(sig("deep")).to include("class B < ::Lib::C::B\n")
      expect(sig("deep")).not_to include("< ::Lib::C::D::B")
      expect(validation_errors).to be_empty
    end

    # A top-level outer class: `B` inside `module Lib` names the top-level `::B` when `Lib::B` is the class opened.
    it "resolves a nested superclass of the same name to a top-level class" do
      run_generator(
        "lib/top.rb" => <<~RUBY
          class B
            def t = 1
          end
          module Lib
            class B < B
              def u = 2
            end
          end
        RUBY
      )

      expect(sig("top")).to include("class B < ::B\n")
      expect(validation_errors).to be_empty
    end

    # No outer class of that name exists, so the superclass is unresolvable and the class is demoted (#735).
    it "demotes a nested superclass of its own name when no outer class answers" do
      candidates, generator = run_generator(
        "lib/nested_only.rb" => <<~RUBY
          module Lib
            module C
              class B < B
                def x = 1
              end
            end
          end
        RUBY
      )

      expect(sig("nested_only")).to be_nil
      expect_demoted(candidates, :x)
      expect(generator.unresolvable_superclasses).to eq("Lib::C::B" => "B")
      expect(validation_errors).to be_empty
    end
  end
end
