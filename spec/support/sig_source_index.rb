# frozen_string_literal: true

# Issue #839 — "does the method this declaration describes exist at all?", asked of two sources of
# truth beside `sig-gen`.
#
# `sig-gen` enumerates `def`s. `sig/` declares methods, and a method is not always a `def`: an
# `attr_*`, a `define_method`, an `alias`, a `Data.define` / `Struct.new` member, a method reached
# through a superclass or a mixin, a method compiled onto a class at load
# (`Rigor::Source::NodeChildren`). {SigProvenanceAuditor} called every one of those `:no_source`
# together with the declarations whose `def` had been **deleted or renamed** — and the audit
# (`docs/notes/20260908-sig-provenance-audit.md`) found nine of the latter sitting in `sig/`, which
# neither `make check` nor `make steep-check` can see: both ask whether the implementation matches
# `sig/`, never the converse.
#
# This index answers the converse, in two tiers, so `:no_source` can mean **stale** and nothing else.
#
# == Tier 1 — Rigor's own recognition (static, always on)
#
# `Inference::ScopeIndexer.discovered_project_index_for_paths` is the same cross-file pre-pass
# `Analysis::Runner` builds before a `rigor check`: it already recognises `attr_*`, `define_method`,
# `alias` / `alias_method`, `module_function`, an `extend` fold, and `Data` / `Struct` member
# layouts, because the `call.undefined-method` rule would fire on all of them otherwise. Asking it
# rather than re-deriving the shapes keeps one recognition in the tree — a second one would drift,
# and the drift would show up as a false stale-declaration report, which AGENTS.md
# § "Implementation Guidelines" ranks above any worst-case reading. The ancestor walk
# (`Scope#discovered_method_through_ancestors?`) comes with it, so a method the project declares on
# a superclass or an included module resolves without a second traversal.
#
# == Tier 2 — the runtime (reflection, opt-in)
#
# What no static pass can see: `Rigor::ValueSemantics#value_fields` defines `==` / `eql?` / `hash`
# from a class macro, `Data.define` generates `.new` and `#with` on an anonymous parent, and
# `Rigor::Source::NodeChildren` compiles `#rigor_each_child` onto every concrete `Prism::*Node`
# class at load — the case `sig/prism_node_children.rbs` documents in prose. Reflection over a
# loaded tree confirms each of them, the way `spec/rigor/public_api_drift_spec.rb` already reflects
# over the public surface, and confirming beats an exemption list: an exemption stays true after the
# code under it is deleted.
#
# Loading a tree runs its code, so tier 2 is **opt-in** (`runtime: true`) and only ever pointed at
# this repository. A fixture project must never be required: its `lib/` is written by the example
# that is auditing it.
require "rigor"

class SigSourceIndex
  # A method the project defines on the declaring class by a shape that is not a `def` sig-gen
  # enumerates — or a `def` sig-gen deliberately declines to emit (a parameterless `initialize`).
  SYNTHETIC = :synthetic
  # The project declares the method on an ancestor it also declares (a superclass, or an included
  # module).
  INHERITED = :inherited
  # Only reflection over the loaded tree finds it: generated at load, by a class macro or by a
  # generated ancestor.
  RUNTIME = :runtime

  # Explains nothing, so every unmatched declaration reads as stale. The default, because the
  # alternative default would require a fixture tree's `lib/`.
  NONE = Object.new
  def NONE.explain(*) = nil
  NONE.freeze

  class << self
    # @param root — the project root.
    # @param paths — the source directories, as `Configuration#paths` spells them.
    # @param runtime — require the tree and reflect over it (tier 2). Never true for a fixture.
    def build(root:, paths: ["lib"], runtime: false)
      new(root: root, paths: paths, runtime: runtime)
    end
  end

  def initialize(root:, paths:, runtime:)
    @root = root
    @paths = paths
    @runtime = runtime
  end

  # `[SYNTHETIC | INHERITED | RUNTIME, detail]` for a method that exists, nil for one that does not.
  #
  # Deliberately kind-blind, matching the join {SigProvenanceAuditor} makes against `sig-gen`'s
  # candidates: `def self?.x` in RBS and `module_function` in Ruby disagree about which kind a module
  # function is, and answering "this method does not exist" off that disagreement would be a false
  # report of a stale declaration.
  #
  # @param class_name — the qualified class the declaration is nested in.
  # @param method_name — the declared method name, `=` suffix included for a writer.
  def explain(class_name, method_name)
    synthetic(class_name, method_name) || project_ancestor(class_name, method_name) ||
      runtime(class_name, method_name)
  end

  # The tier-1 tables, for a caller reporting on the pass itself.
  def project_index
    @project_index ||= Rigor::Inference::ScopeIndexer.discovered_project_index_for_paths(ruby_files)
  end

  private

  def def_index = project_index.fetch(:def_index)

  def ruby_files
    @ruby_files ||= @paths.flat_map { |path| Dir.glob(File.join(@root, path, "**/*.rb")) }.sort
  end

  def synthetic(class_name, method_name)
    return [SYNTHETIC, "Data member"] if member?(def_index.fetch(:data_member_layouts)[class_name], method_name)
    return [SYNTHETIC, "Struct member"] if struct_member?(class_name, method_name)
    return nil unless %i[instance singleton].any? { |kind| scope.discovered_method?(class_name, method_name, kind) }

    [SYNTHETIC, accessor?(class_name, method_name) ? "attr_* / define_method / alias_method" : "def or alias"]
  end

  # Named for the question, not for the answer: `inherited` is `Class`'s own hook name, and a private
  # helper that shadows it reads as an override of it.
  def project_ancestor(class_name, method_name)
    walked = %i[instance singleton].any? do |kind|
      scope.discovered_method_through_ancestors?(class_name, method_name, kind)
    end
    walked ? [INHERITED, "project ancestor"] : nil
  end

  def runtime(class_name, method_name)
    return nil unless @runtime

    load_project
    owner = runtime_owner(constant(class_name), method_name)
    owner && [RUNTIME, owner]
  end

  # `Data.define` members carry no writer (a Data instance is frozen); a `Struct.new` member carries
  # both, so the writer's `=` is stripped before the layout is consulted.
  def member?(members, method_name)
    !members.nil? && members.map(&:to_s).include?(method_name)
  end

  def struct_member?(class_name, method_name)
    layout = def_index.fetch(:struct_member_layouts)[class_name]
    member?(layout && layout[:members], method_name.delete_suffix("="))
  end

  # True when the name is in the accessor / alias / `define_method` existence table rather than the
  # def-node table. `finalize_def_index` subtracts def-declared names from the former (a cross-file
  # suppression contract that has nothing to do with existence), which is why {#existence_table}
  # merges the two back together and only the shape label reads them apart.
  def accessor?(class_name, method_name)
    (def_index.fetch(:methods)[class_name] || {}).key?(method_name.to_sym)
  end

  # One scope carrying the whole project's discovery tables, so `Scope`'s own ancestor walk answers
  # the mixin / superclass half rather than a second traversal written here.
  def scope
    @scope ||= Rigor::Scope.empty(environment: Rigor::Environment.default).with_discovery(
      Rigor::Scope::DiscoveryIndex::EMPTY.with(
        discovered_classes: project_index.fetch(:classes),
        discovered_methods: existence_table,
        discovered_def_nodes: def_index.fetch(:def_nodes),
        discovered_singleton_def_nodes: def_index.fetch(:singleton_def_nodes),
        discovered_superclasses: def_index.fetch(:superclasses),
        discovered_header_nestings: def_index.fetch(:header_nestings),
        discovered_includes: def_index.fetch(:includes),
        data_member_layouts: def_index.fetch(:data_member_layouts),
        struct_member_layouts: def_index.fetch(:struct_member_layouts)
      )
    )
  end

  # The union of every shape the pre-pass recognises, keyed the way `Scope#discovered_method?` reads
  # it. `def_index[:methods]` alone would miss every plain `def` (see {#accessor?}) and so would
  # report an inherited `def` as a stale declaration.
  def existence_table
    @existence_table ||= begin
      table = {}
      def_index.fetch(:methods).each { |name, entries| entries.each { |m, kind| record(table, name, m, kind) } }
      def_index.fetch(:def_nodes).each { |name, entries| entries.each_key { |m| record(table, name, m, :instance) } }
      def_index.fetch(:singleton_def_nodes).each do |name, entries|
        entries.each_key { |m| record(table, name, m, :singleton) }
      end
      table.each_value(&:freeze).freeze
    end
  end

  def record(table, class_name, method_name, kind)
    entries = (table[class_name] ||= {})
    recorded = entries[method_name]
    entries[method_name] = recorded.nil? || recorded == kind ? kind : Rigor::Scope::DiscoveryIndex::METHOD_KIND_BOTH
  end

  def constant(class_name)
    Object.const_get(class_name)
  rescue NameError, TypeError
    nil
  end

  # Every object answers `hash`, `==`, `to_s` and `inspect`, and `sig/` declares all four on classes
  # that generate them from `ValueSemantics#value_fields`. Reflection alone would therefore confirm
  # such a declaration after the `value_fields` call under it was deleted — the exact miss this index
  # exists to close. An owner that hands the method to EVERY object explains nothing, so it is read
  # as no owner at all.
  UNIVERSAL_INSTANCE_OWNERS = [Object, Kernel, BasicObject].freeze
  UNIVERSAL_SINGLETON_OWNERS = [Class, Module, Object, Kernel, BasicObject].freeze
  private_constant :UNIVERSAL_INSTANCE_OWNERS, :UNIVERSAL_SINGLETON_OWNERS

  # Instance side first, then singleton, then the subclasses — mirroring {#explain}'s kind-blindness.
  # The subclass sweep is what confirms `sig/prism_node_children.rbs`: `#rigor_each_child` is
  # compiled onto every CONCRETE `Prism::*Node`, and declared on the abstract `Prism::Node` so every
  # subclass resolves against one declaration.
  def runtime_owner(klass, method_name)
    return nil unless klass.is_a?(Module)

    instance_owner(klass, method_name) || singleton_owner(klass, method_name) ||
      (subclass_defines?(klass, method_name) ? "compiled onto every subclass at load" : nil)
  end

  def instance_owner(klass, method_name)
    owner = klass.instance_method(method_name).owner
    return nil if UNIVERSAL_INSTANCE_OWNERS.include?(owner)
    return "defined on the class itself at load" if owner == klass

    "inherited from #{owner.name || 'a generated ancestor'}"
  rescue NameError
    nil
  end

  def singleton_owner(klass, method_name)
    owner = klass.method(method_name).owner
    return nil if UNIVERSAL_SINGLETON_OWNERS.include?(owner)

    # A singleton class has no name of its own (`#<Class:Foo>`); the class it is attached to is the
    # legible half, and `attached_object` is the only way back to it.
    attached = owner.respond_to?(:attached_object) ? owner.attached_object : nil
    "singleton method, from #{singleton_source(attached, klass)}"
  rescue NameError
    nil
  end

  def singleton_source(attached, klass)
    return "the class itself at load" if attached.equal?(klass)

    attached.is_a?(Module) && attached.name ? attached.name : "a generated ancestor"
  end

  def subclass_defines?(klass, method_name)
    return false unless klass.is_a?(Class)

    ObjectSpace.each_object(Class).any? do |candidate|
      candidate < klass && candidate.method_defined?(method_name.to_sym, false)
    end
  end

  # `lib/rigortype.rb` is excluded on purpose: requiring it is the mistake it exists to warn about
  # (`require "rigortype"` prints a paragraph telling you Rigor is not a library), and it declares
  # nothing `sig/` describes. Everything else is required, because `require "rigor"` alone leaves
  # ~110 files unloaded — the whole CLI, LSP and MCP surface — and five `CLI::*Command#initialize`
  # declarations resolve only once their file is loaded.
  def load_project
    return if @loaded

    @loaded = true
    ruby_files.each do |file|
      require file unless File.basename(file) == "rigortype.rb"
    end
  end
end
