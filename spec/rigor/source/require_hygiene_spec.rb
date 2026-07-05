# frozen_string_literal: true

require "spec_helper"
require "prism"

# Guards the per-consumer require discipline for the `Rigor::Source::*` helpers.
#
# `lib/rigor.rb` requires the `source.rb` aggregator, which pulls in every `source/*` helper. But the CLI entry point
# never loads `lib/rigor.rb` — `exe/rigor` does `require "rigor/cli"`, which lazily requires only the command it runs,
# and each engine file requires its own dependencies. So a lib file that *uses* a Source helper while leaning on the
# aggregator to load it raises `uninitialized constant Rigor::Source::X` at analyzer runtime, even though the spec suite
# (which boots via `require "rigor"` in spec_helper, loading the aggregator) hides the gap entirely.
#
# `make check` catches such a gap only when the constant is loaded nowhere else on the CLI path; a helper already pulled
# in by some earlier require is masked by load order. This spec closes both holes by asserting, statically, that every
# file referencing a Source helper requires it directly. Add a row to `helpers` when a new `source/*` helper lands.
# Source helper constant name => its file basename under lib/rigor/source/. Lives in a module (not inside the example
# group) so it can drive example generation without tripping the no-constant-in-block / leaky-local cops.
module SourceRequireHygiene
  HELPERS = {
    NodeWalker: "node_walker",
    NodeLocator: "node_locator",
    Literals: "literals",
    ConstantPath: "constant_path"
  }.freeze
end

RSpec.describe "Rigor::Source helper require hygiene" do
  def lib_root
    File.expand_path("../../../lib", __dir__)
  end

  def lib_files
    Dir.glob(File.join(lib_root, "rigor", "**", "*.rb"))
  end

  # Every helper from `names` referenced in `ast` (AST only — a mention in a comment or string is not a
  # ConstantPathNode, so it never counts). Both the lexical `Source::X` and the fully-qualified `Rigor::Source::X` forms
  # count.
  def source_helpers_referenced(ast, names)
    referenced = []
    visit = lambda do |node|
      return unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::ConstantPathNode) && names.include?(node.name) && rooted_in_source?(node.parent)
        referenced << node.name
      end
      node.compact_child_nodes.each { |child| visit.call(child) }
    end
    visit.call(ast)
    referenced.uniq
  end

  # True when `parent` is the `Source` segment of a `Source::X` / `*::Source::X` path.
  def rooted_in_source?(parent)
    (parent.is_a?(Prism::ConstantReadNode) || parent.is_a?(Prism::ConstantPathNode)) &&
      parent.name == :Source
  end

  def requires_helper?(source, basename)
    source.match?(%r{require_relative\s+"(\.\./)*source/#{Regexp.escape(basename)}"})
  end

  SourceRequireHygiene::HELPERS.each do |helper, basename|
    it "every lib file referencing Source::#{helper} requires source/#{basename} directly" do
      names = SourceRequireHygiene::HELPERS.keys
      offenders = lib_files.reject do |path|
        next true if path == File.join(lib_root, "rigor", "source", "#{basename}.rb")

        source = File.read(path, encoding: Encoding::UTF_8)
        ast = Prism.parse(source).value
        next true unless source_helpers_referenced(ast, names).include?(helper)

        requires_helper?(source, basename)
      end

      relative = offenders.map { |p| p.delete_prefix("#{lib_root}/") }
      expect(offenders).to be_empty, <<~MSG
        These files reference Rigor::Source::#{helper} but do not
        `require_relative` source/#{basename} directly. They work under
        `require "rigor"` (the aggregator) but raise an uninitialized-constant
        error on the CLI load path. Add the direct require:

        #{relative.join("\n")}
      MSG
    end
  end
end
