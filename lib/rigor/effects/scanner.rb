# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/node_children"
require_relative "attribution"
require_relative "envelope_index"
require_relative "file_collection"
require_relative "local_ownership"
require_relative "origin"
require_relative "framework_units"
require_relative "plugin_facts"
require_relative "summary"
require_relative "unit_scan"

module Rigor
  module Effects
    # Turns one file's AST plus the call decisions the typer recorded for it into a {FileCollection}.
    #
    # The scanner owns **identity** — which effect units the file defines and what each is keyed as — and
    # delegates each unit's body to {UnitScan}. Keys follow the existing symbol tables (ADR-103 WD14):
    # `Class#m` for an instance method, `Class.m` for a singleton one, and `<toplevel>#m` for a `def`
    # outside any class body. Reopenings in one file join here; reopenings across files join when the
    # runner merges the collections.
    #
    # Three kinds of unit exist beyond a plain `def`:
    #
    # - `define_method(:literal) { … }` — the block is the method's body. The def-node discovery tables
    #   skip it, so this is the minimal extension WD14 calls for, made here rather than in `ScopeIndexer`
    #   because nothing outside effects needs it yet.
    # - `attr_reader` / `attr_writer` / `attr_accessor` — synthesised: a reader is ∅, a writer is
    #   `mutate.self`. Without them a caller's edge into an accessor would read as unresolved.
    # - a nested `def` — its own unit under the same class, never contained in the enclosing method.
    #
    # **This walk exists only when collection is on.** ADR-103 WD13 prefers riding `ScopeIndexer`'s
    # existing `def` descent; a separate walk is taken here because the scanner must also attribute each
    # recorded call *node* to its enclosing unit, and doing that inside the indexer would put an
    # effects-shaped concern on the hot path for every run. Off, this file is never loaded past `require`.
    class Scanner
      # Mirrors `Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY`. Spelled again rather than required so the
      # effects namespace does not pull the indexer in; the two are pinned together by spec.
      TOP_LEVEL_KEY = "<toplevel>"

      # Receiver-less calls in a class / module body that {#record_declaration} interprets. Everything
      # else in a class body is out of scope in v1 — its statements run at load time, which is a unit of
      # its own that no slice models yet.
      DECLARATION_MACROS = %i[include prepend attr_reader attr_writer attr_accessor define_method].to_set.freeze

      MUTATE_SELF = LabelSet.new(["mutate.self"])
      private_constant :MUTATE_SELF

      # A synthesised writer's summary is the same value at every `attr_accessor` in the project, so it is
      # built once rather than per accessor.
      WRITER_SUMMARY = Summary.new(bundles: { Origin.construct("attr-writer") => MUTATE_SELF })
      private_constant :WRITER_SUMMARY

      def self.scan(root:, path:, calls:, attribution: Attribution.empty, envelopes: EnvelopeIndex.empty,
                    plugin_facts: PluginFacts.empty)
        new(path: path, calls: calls, attribution: attribution, envelopes: envelopes,
            plugin_facts: plugin_facts).scan(root)
      end

      def initialize(path:, calls:, attribution: Attribution.empty, envelopes: EnvelopeIndex.empty,
                     plugin_facts: PluginFacts.empty)
        @path = path
        @calls = calls
        @attribution = attribution
        @envelopes = envelopes
        @plugin_facts = plugin_facts
        @summaries = {}
        @edges = {}
        @superclasses = {}
        @includes = {}
        # ADR-103 WD10 / #387 — the class-body facts the framework-edge strategies read, harvested only
        # when a loaded plugin declared one. A run with no `effect_edges:` never allocates them.
        @harvest = plugin_facts.edges? ? {} : nil
      end

      def scan(root)
        walk(root, [], false)
        synthesize_framework_units
        FileCollection.new(
          path: @path, summaries: @summaries, edges: @edges,
          superclasses: @superclasses, includes: @includes
        )
      end

      private

      def walk(node, prefix, singleton)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return walk_namespace(node, prefix)
        when Prism::SingletonClassNode
          return walk(node.body, prefix, true) if node.body
        when Prism::DefNode
          return enter_def(node, prefix, singleton)
        when Prism::CallNode
          harvest_class_body_macro(node, prefix)
          return record_declaration(node, prefix) if declaration?(node)
        end

        node.rigor_each_child { |child| walk(child, prefix, singleton) }
      end

      def walk_namespace(node, prefix)
        nested = Source::ConstantPath.declaration_prefix(prefix, node.constant_path)
        return node.rigor_each_child { |child| walk(child, prefix, false) } if nested.nil?

        record_superclass(nested.join("::"), node, prefix) if node.is_a?(Prism::ClassNode)
        walk(node.body, nested, false) if node.body
      end

      def enter_def(node, prefix, singleton)
        own_singleton = singleton || !node.receiver.nil?
        scan = add_unit(class_name_for(prefix), node.name.to_s, own_singleton, node.body, node.parameters)
        harvest_def(prefix, node.name.to_s, own_singleton, scan) if @harvest && !prefix.empty?
      end

      # What the framework strategies need to know about a `def` the class body spelled out itself: that it
      # exists, and whether it reaches `super`. `:defs` stays instance-only, because a mailer action is an
      # instance method; `:units` is keyed by the suffix a synthetic unit key carries, so both sides of the
      # `#` / `.` split are answerable (#440). A body the collector could not finish reads as delegating,
      # which keeps the framework's claim — the fail-soft direction for an upper bound.
      def harvest_def(prefix, name, singleton, scan)
        entry = harvest_for(prefix)
        entry[:defs] << name unless singleton
        entry[:units]["#{singleton ? '.' : '#'}#{name}"] = scan.nil? || scan.delegates_upward?
      end

      # ADR-103 WD10 — a receiver-less call in a class body, recorded as `macro => [literal symbol
      # arguments]`. That is all the framework-edge strategies need: `before_save :normalize` names a
      # method on the same class, and a computed callback (`before_save -> { … }`, a method object) names
      # none the strategy could resolve, so it contributes nothing rather than a guess. The block form is
      # already contained in the class body, which v1 does not model as a unit at all.
      def harvest_class_body_macro(node, prefix)
        return if @harvest.nil? || prefix.empty? || !node.receiver.nil?

        entry = harvest_for(prefix)
        name = node.name.to_s
        if FrameworkUnits::CALLBACK_MACROS.include?(name)
          (entry[:macros][name] ||= []).concat(symbol_arguments(node))
        elsif uniqueness_validator?(node, name)
          entry[:uniqueness] = true
        end
      end

      # `validates :email, uniqueness: true` and `validates_uniqueness_of :email` — the validation whose
      # implementation is a `SELECT`.
      def uniqueness_validator?(node, name)
        return true if name == FrameworkUnits::UNIQUENESS_MACRO
        return false unless name == FrameworkUnits::VALIDATES_MACRO

        node.arguments&.arguments&.any? do |argument|
          argument.is_a?(Prism::KeywordHashNode) && argument.elements.any? do |element|
            element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) &&
              element.key.unescaped == FrameworkUnits::UNIQUENESS_OPTION
          end
        end || false
      end

      def harvest_for(prefix)
        @harvest[class_name_for(prefix)] ||= { defs: [], units: {}, macros: {}, uniqueness: false }
      end

      # Files the units the framework contributes for each class this file declares. Runs after the walk,
      # because a callback macro may be written below the `def` it names and a mailer action may be
      # declared anywhere in the body.
      def synthesize_framework_units
        return if @harvest.nil?

        @harvest.each do |class_name, entry|
          FrameworkUnits.synthesize(
            class_name: class_name, instance_methods: entry[:defs], macros: entry[:macros],
            uniqueness: entry[:uniqueness], plugin_facts: @plugin_facts, own_units: entry[:units]
          ).each { |key, summary, edges| merge_unit(key, summary, edges) }
        end
      end

      # Scans one unit and files its summary, then recurses into the units its body declared. Fail-soft
      # per unit (ADR-103 WD13): a unit the scanner cannot finish is recorded as non-exhaustive with
      # `collector-error` and its siblings are unaffected.
      #
      # @return [UnitScan, nil] the finished scan, or nil when the unit failed soft
      def add_unit(class_name, method_name, singleton, body, parameters)
        key = "#{class_name}#{singleton ? '.' : '#'}#{method_name}"
        names = parameter_names(parameters)
        scan = UnitScan.new(
          singleton: singleton, parameters: names,
          block_parameter: block_parameter_name(parameters),
          owned_locals: LocalOwnership.owned(body, names), calls: @calls,
          attribution: @attribution, envelopes: @envelopes, plugin_facts: @plugin_facts,
          owner_class: class_name, method_name: method_name
        )
        summary, edges = scan.run(body)
        merge_unit(key, summary, edges)
        scan.nested.each do |name, nested_singleton, nested_body, nested_parameters|
          add_unit(class_name, name, singleton || nested_singleton, nested_body, nested_parameters)
        end
        scan
      rescue StandardError
        merge_unit(key, Summary.tainted("collector-error", method_name), [])
        nil
      end

      # A receiver-less call in a class / module body that declares units or ancestry. Class bodies are
      # not themselves effect units in v1 (their statements run at load time), so nothing else in one
      # contributes labels — but `include` and the accessor macros decide what the *methods* are.
      def declaration?(node)
        node.receiver.nil? && DECLARATION_MACROS.include?(node.name)
      end

      def record_declaration(node, prefix)
        class_name = class_name_for(prefix)
        case node.name
        when :include, :prepend then record_includes(class_name, node, prefix)
        when :define_method then declare_define_method(class_name, node)
        else synthesize_accessors(class_name, node)
        end
      end

      def declare_define_method(class_name, node)
        unit = UnitScan.define_method_unit(node)
        return if unit.nil?

        name, singleton, body, parameters = unit
        add_unit(class_name, name, singleton, body, parameters)
      end

      def synthesize_accessors(class_name, node)
        symbol_arguments(node).each do |name|
          merge_unit("#{class_name}##{name}", Summary.empty, []) unless node.name == :attr_writer
          next if node.name == :attr_reader

          merge_unit("#{class_name}##{name}=", WRITER_SUMMARY, [])
        end
      end

      def record_includes(class_name, node, prefix)
        names = constant_arguments(node).flat_map { |name| lexical_candidates(name, prefix) }
        (@includes[class_name] ||= []).concat(names) unless names.empty?
      end

      def record_superclass(full_name, node, prefix)
        superclass = node.superclass && Source::ConstantPath.qualified_name(node.superclass)
        @superclasses[full_name] = lexical_candidates(superclass, prefix) if superclass
      end

      # An ancestry name is recorded AS WRITTEN — `class Loud < Base` inside `module Tracer` names
      # `Base`, not `Tracer::Base` — and a single file cannot say which constant that resolves to. So the
      # scanner records the candidates Ruby's own lexical lookup would try, most-qualified first, and the
      # propagator picks the one the merged project actually defines. Same shape as `ScopeIndexer`'s
      # as-written superclass table, resolved at the same point: when the whole project is in view.
      def lexical_candidates(name, prefix)
        return [name] if prefix.empty? || name.start_with?("#{prefix.join('::')}::")

        prefix.length.downto(1).map { |depth| "#{prefix.first(depth).join('::')}::#{name}" } + [name]
      end

      def merge_unit(key, summary, edges)
        @summaries[key] = @summaries.key?(key) ? @summaries[key].join(summary) : summary
        (@edges[key] ||= []).concat(edges) unless edges.empty?
      end

      def class_name_for(prefix)
        prefix.empty? ? TOP_LEVEL_KEY : prefix.join("::")
      end

      def symbol_arguments(node)
        node.arguments&.arguments&.filter_map { |argument| argument.unescaped if argument.is_a?(Prism::SymbolNode) } ||
          []
      end

      def constant_arguments(node)
        node.arguments&.arguments&.filter_map { |argument| Source::ConstantPath.qualified_name(argument) } || []
      end

      def parameter_names(parameters)
        return Set.new unless parameters.is_a?(Prism::ParametersNode)

        names = Set.new
        [parameters.requireds, parameters.optionals, parameters.posts, parameters.keywords].each do |group|
          group.each { |parameter| names << parameter.name.to_s if parameter.respond_to?(:name) && parameter.name }
        end
        [parameters.rest, parameters.keyword_rest].each do |parameter|
          names << parameter.name.to_s if parameter.respond_to?(:name) && parameter&.name
        end
        names
      end

      def block_parameter_name(parameters)
        return nil unless parameters.is_a?(Prism::ParametersNode)

        parameters.block&.name&.to_s
      end
    end
  end
end
