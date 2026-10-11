# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/analysis/dependency_source_inference"

# ADR-121 WD7, issue #1814 — the gem source walker reads a gem file through the census the project walk runs
# (`ScopeIndexer.refinement_table`, which is `build_methods_and_def_nodes`'s refinement table), so a gem module's rows
# carry the wildcards a project module's would. Each source below is one `refine` shape of
# `spec/rigor/inference/scope_indexer/refine_census_spec.rb`, written to a gem's `lib/` and to a project file's tree:
# the two walks must produce the same table. A fixture that records nothing in both would pass vacuously, so every one
# but the DSL and data shapes (`:empty`) must record a row.
RSpec.describe Rigor::Analysis::DependencySourceInference::Walker, ".walk" do
  def project_table(source)
    Rigor::Inference::ScopeIndexer.build_methods_and_def_nodes(Prism.parse(source).value).fetch(3)
  end

  def gem_table(*sources)
    Dir.mktmpdir("parity-gem-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      sources.each_with_index { |source, index| File.write(File.join(dir, "lib", "f#{index}.rb"), source) }
      return described_class.walk(gem_dir: dir, roots: %w[lib]).refinements
    end
  end

  fixtures = {
    "a literal target and block" => ["module M\n  refine(String) { def shout = 1 }\nend\n", :rows],
    "a project constant alias as the target" => [
      "K = String\nmodule M\n  refine(K) { def center(a, b, c) = 1 }\nend\n", :rows
    ],
    "a non-literal target in a block" => [
      "module M\n  [String, Symbol].each { |k| refine(k) { def center(a, b, c) = 1 } }\nend\n", :rows
    ],
    "a body whose names are incomplete" => [
      "module M\n  refine(String) { import_methods Helper }\nend\n", :rows
    ],
    "a target the file binds by ||=" => [
      "K ||= String\nmodule M\n  refine(K) { def center(a, b, c) = 1 }\nend\n", :rows
    ],
    "refine(self)" => ["module M\n  refine(self) { def shout = 1 }\nend\n", :rows],
    "a refine in an instance method" => [
      "module Helper\n  def setup = refine(String) { def shout = 1 }\nend\n", :rows
    ],
    "a refine in a def self.x" => [
      "module M\n  def self.setup\n    refine(String) { def shout = 1 }\n  end\nend\n", :rows
    ],
    "a refine in a def in class << self" => [
      "module M\n  class << self\n    def setup = refine(String) { def shout = 1 }\n  end\nend\n", :rows
    ],
    "a refine in a define_method block" => [
      "module Helper\n  define_method(:setup) { refine(String) { def center(a, b, c) = 1 } }\nend\n", :rows
    ],
    "a refine in a top-level block an eval may run" => [
      "module Ext\n  def self.define(&blk) = module_eval(&blk)\nend\nExt.define do\n  " \
      "refine(String) { def center(a, b, c) = 1 }\nend\n", :rows
    ],
    "a refine in an eval block on a constant inside a def self.x" => [
      "module Installer\n  def self.install = Ext.module_eval { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      :rows
    ],
    "a block-form module_eval on a constant" => [
      "module L\n  M.module_eval { refine(String) { def shout = 1 } }\nend\n", :rows
    ],
    "a refine in a core iterator's block on a constant" => [
      "module M\n  TARGETS = [String, Symbol].freeze\n  " \
      "TARGETS.each { |k| refine(k) { def center(a, b, c) = 1 } }\nend\n", :rows
    ],
    "send(:refine, …) on a constant" => ["M.send(:refine, String) { def shout = 1 }\n", :rows],
    "alias_method :my_refine, :refine in class << self" => [
      "module M\n  class << self\n    alias_method :my_refine, :refine\n  end\nend\n", :rows
    ],
    "a string-form module_eval" => ["module L\n  M.module_eval(\"refine(String) { def shout = 1 }\")\nend\n", :rows],
    "a :refine literal at the top level" => ["x = Module.private_method_defined?(:refine)\n", :rows],
    "a refine heredoc an endless def evals" => [
      "module Ext\n  def self.install = module_eval(<<~RUBY)\n    refine(String) { def center(a, b, c) = 1 }\n  " \
      "RUBY\nend\n", :rows
    ],
    "a Module.new block written to a constant" => [
      "Ext = Module.new do\n  refine(String) { def shout = 1 }\nend\n", :rows
    ],
    "a bare Module.new block" => [
      "using Module.new { refine(String) { def whisper = 1 } }\n" \
      "Module.new do\n  refine(String) { def other = 1 }\nend\n", :rows
    ],
    "a refine in a Module subclass's instance method" => [
      "class MyMod < Module\n  def setup = refine(String) { def shout = 1 }\nend\n", :rows
    ],
    "a refine with no enclosing module" => ["refine(::String) { def shout = nil }\n", :rows],
    "a nested refine in a refine body" => [
      "module M\n  refine(String) do\n    refine(Integer) { def twice = 1 }\n    def shout = 1\n  end\nend\n", :rows
    ],
    "a refine in a def in a refine body" => [
      "module M\n  refine(Module) do\n    def setup = refine(String) { def shout = 1 }\n  end\nend\n", :rows
    ],
    "a refine above binary __END__ data" => [
      "module M\n  refine(String) { def shout = 1 }\nend\n__END__\n\x89PNG\xff\xfe refine\n", :rows
    ],
    "a refine in a class body (the class's own method)" => [
      "class C\n  refine(String) { def label = 1 }\nend\n", :empty
    ],
    "a refine in a plain class's methods" => [
      "class Query\n  def refine(extra) = yield(extra)\n  def narrowed = refine(1) { |q| q }\nend\n", :empty
    ],
    "a :refine Symbol in a plain class's method" => ["class Controller\n  def action_name = :refine\nend\n", :empty],
    "a file that never names refine" => ["module M\n  def shout = 1\nend\n", :empty]
  }

  describe "census parity with the project walk" do
    fixtures.each do |name, (source, expectation)|
      it "reads #{name} as the project walk does" do
        table = project_table(source)

        expect(gem_table(source)).to eq(table)
        expectation == :rows ? expect(table).not_to(be_empty) : expect(table).to(be_empty)
      end
    end

    # The project folds its files' tables with `merge_refinement_tables`; the gem walk folds the same way.
    it "folds the tables of several files as the project does" do
      first = "module A\n  refine(String) { def shout = 1 }\nend\n"
      second = "module B\n  refine(String) { def shout = 2; def other = 3 }\n  " \
               "def self.setup = refine(Integer) { }\nend\n"
      folded = Rigor::Inference::ScopeIndexer.merge_refinement_tables(project_table(first), project_table(second))

      expect(gem_table(first, second)).to eq(folded)
      expect(folded.dig("String", :shout)).to eq(%w[A B])
    end
  end
end
