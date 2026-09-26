# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/node_children"
require_relative "ancestry_recorder"
require_relative "attribution"
require_relative "definition_context"
require_relative "envelope_index"
require_relative "file_collection"
require_relative "local_ownership"
require_relative "origin"
require_relative "framework_units"
require_relative "plugin_facts"
require_relative "summary"
require_relative "unit_scan"
require_relative "visibility"

module Rigor
  module Effects
    # Turns one file's AST plus the call decisions the typer recorded for it into a {FileCollection}.
    #
    # The scanner owns **identity** — which effect units the file defines and what each is keyed as — and
    # delegates each unit's body to {UnitScan}. Keys follow the existing symbol tables (ADR-103 WD14):
    # `Class#m` for an instance method, `Class.m` for a singleton one, and `<toplevel>#m` for a `def`
    # outside any class body. The side is the one Ruby defines the method on, which the enclosing method
    # does not decide: {DefinitionContext} carries it down the walk, and a definition it cannot place is
    # no unit. Reopenings in one file join here; reopenings across files join when the runner merges the
    # collections.
    #
    # Three kinds of unit exist beyond a plain `def`:
    #
    # - `define_method(:literal) { … }` — the block is the method's body. The def-node discovery tables
    #   skip it, so this is the minimal extension WD14 calls for, made here rather than in `ScopeIndexer`
    #   because nothing outside effects needs it yet.
    # - `attr_reader` / `attr_writer` / `attr_accessor` — synthesised: a reader is ∅, a writer is
    #   `mutate.self` (`mutate.static` where `self` is the singleton class, since it writes the class
    #   object's ivar).
    #   Without them a caller's edge into an accessor would read as unresolved.
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

      # A synthesised writer's summary is the same value at every `attr_accessor` in the project, so it is
      # built once rather than per accessor. A singleton writer sets an ivar on the class object, and is
      # labelled as an ivar write in a body that runs on a class is.
      WRITER_SUMMARY = Summary.new(bundles: { Origin.construct("attr-writer") => UnitScan::MUTATE_SELF })
      SINGLETON_WRITER_SUMMARY = Summary.new(bundles: { Origin.construct("attr-writer") => UnitScan::MUTATE_STATIC })
      private_constant :WRITER_SUMMARY, :SINGLETON_WRITER_SUMMARY

      # Every argument is one collection input the scan reads; a context object would move the same list
      # one call further out.
      # rubocop:disable Metrics/ParameterLists
      def self.scan(root:, path:, calls:, attribution: Attribution.empty, envelopes: EnvelopeIndex.empty,
                    plugin_facts: PluginFacts.empty, unit_key: nil, unit_owner: nil)
        new(path: path, calls: calls, attribution: attribution, envelopes: envelopes,
            plugin_facts: plugin_facts, unit_key: unit_key, unit_owner: unit_owner).scan(root)
      end

      def initialize(path:, calls:, attribution: Attribution.empty, envelopes: EnvelopeIndex.empty,
                     plugin_facts: PluginFacts.empty, unit_key: nil, unit_owner: nil)
        # rubocop:enable Metrics/ParameterLists
        @path = path
        # #392 — a template unit: the WHOLE file is one effect unit, keyed `view:<logical_name>`. A
        # template has no `def` to key on and no owner class of its own, so the ordinary walk — which only
        # ever mints a unit at a `def` — would report nothing for a file that calls into the project all
        # the way down.
        @unit_key = unit_key
        # The declared `self` the unit's implicit-self calls resolve against — the plugin's `self_type:`.
        # Without it a helper call in a template reads as an unresolved self-call and taints the unit.
        @unit_owner = unit_owner
        @calls = calls
        @attribution = attribution
        @envelopes = envelopes
        @plugin_facts = plugin_facts
        @summaries = {}
        @edges = {}
        @ancestry = AncestryRecorder.new
        # #1048 — `{class name => Set[method name]}` for the `private` / `protected` members each class
        # body declared. Read only by a UNIT callee rule, and only to decline.
        @non_public = {}
        # ADR-103 WD10 / #387 — the class-body facts the framework-edge strategies read, harvested only
        # when a loaded plugin declared one. A run with no `effect_edges:` never allocates them.
        @harvest = plugin_facts.edges? ? {} : nil
      end

      def scan(root)
        return scan_template_unit(root) if @unit_key

        walk(root, [], DefinitionContext::TOP_LEVEL)
        synthesize_framework_units
        FileCollection.new(
          path: @path, summaries: @summaries, edges: @edges,
          superclasses: @ancestry.superclasses, includes: @ancestry.includes
        )
      end

      private

      # The whole file body as one unit under {@unit_key}. Deliberately NOT combined with the ordinary
      # walk: a compiled template is straight-line statements, a `def` inside one would be a method the
      # render site cannot call, and a second keying rule over the same nodes would double-count every
      # origin in the file.
      def scan_template_unit(root)
        summary, edges = UnitScan.new(
          context: DefinitionContext::INSTANCE_METHOD_BODY, parameters: [], block_parameter: nil,
          owned_locals: LocalOwnership.owned(root, [], singleton: false), calls: @calls,
          attribution: @attribution, envelopes: @envelopes, plugin_facts: @plugin_facts,
          owner_class: @unit_owner, method_name: @unit_key
        ).run(root)
        merge_unit(@unit_key, summary, edges)
        FileCollection.new(path: @path, summaries: @summaries, edges: @edges)
      rescue StandardError
        FileCollection.new(path: @path, summaries: { @unit_key => Summary.tainted("collector-error", @unit_key) })
      end

      # `context` is the {DefinitionContext} of the class-body position `node` sits at. A `class <<` body
      # and a block that rebinds `self` move it; a nested namespace starts afresh.
      def walk(node, prefix, context)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return walk_namespace(node, prefix)
        when Prism::DefNode
          return enter_def(node, prefix, context)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
          @ancestry.record_constant_class(node, prefix)
        when Prism::AliasMethodNode
          return record_initialize_alias(prefix) if @ancestry.alias_to_initialize?(node, context)
        when Prism::CallNode
          harvest_class_body_macro(node, prefix)
          return record_initialize_alias(prefix) if @ancestry.alias_to_initialize?(node, context)
          return record_declaration(node, prefix, context) if declaration?(node)
        end

        rebinds = DefinitionContext.rebinds?(node)
        node.rigor_each_child { |child| walk(child, prefix, rebinds ? context.for_child(node, child) : context) }
      end

      def walk_namespace(node, prefix)
        nested = Source::ConstantPath.declaration_prefix(prefix, node.constant_path)
        return node.rigor_each_child { |child| walk(child, prefix, DefinitionContext::CLASS_BODY) } if nested.nil?

        @ancestry.record_superclass(nested.join("::"), node, prefix) if node.is_a?(Prism::ClassNode)
        return if node.body.nil?

        @non_public[nested.join("::")] = Visibility.non_public_names(node.body)
        walk(node.body, nested, DefinitionContext::CLASS_BODY)
      end

      def enter_def(node, prefix, context)
        body_context = context.def_body(node)
        return if body_context.nil?

        scan = add_unit(class_name_for(prefix), node.name.to_s, body_context, node.body, node.parameters,
                        non_public: non_public?(prefix, node.name.to_s))
        harvest_def(prefix, node.name.to_s, body_context.singleton?, scan) if @harvest && !prefix.empty?
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

      def non_public?(prefix, name)
        prefix.empty? ? false : @non_public[class_name_for(prefix)]&.include?(name) || false
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
      # `context` is the {DefinitionContext} the body runs under, and the unit is keyed singleton exactly
      # when that body runs on a class. The enclosing unit's own bit does not decide where the units nested
      # in it land: `def self.outer` is scanned as a singleton method, and a `def inner` inside it is
      # `Class#inner`.
      #
      # @return the finished scan, or nil when the unit failed soft
      def add_unit(class_name, method_name, context, body, parameters, non_public: false, shared_slot: false)
        key = "#{class_name}#{context.singleton? ? '.' : '#'}#{method_name}"
        names = parameter_names(parameters)
        scan = UnitScan.new(
          context: context, parameters: names,
          block_parameter: block_parameter_name(parameters),
          owned_locals: LocalOwnership.owned(body, names, singleton: context.singleton?), calls: @calls,
          attribution: @attribution, envelopes: @envelopes, plugin_facts: @plugin_facts,
          owner_class: class_name, method_name: method_name, non_public: non_public, shared_slot: shared_slot
        )
        summary, edges = scan.run(body)
        merge_unit(key, summary, edges)
        scan.nested.each do |name, nested_context, nested_body, nested_parameters, nested_shared_slot|
          # A `def` inside a method is never an action, whatever the enclosing body's visibility.
          add_unit(class_name, name, nested_context, nested_body, nested_parameters,
                   non_public: true, shared_slot: nested_shared_slot)
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

      def record_declaration(node, prefix, context)
        class_name = class_name_for(prefix)
        case node.name
        when :include, :prepend then @ancestry.record_includes(class_name, node, prefix, context)
        when :define_method then declare_define_method(class_name, node, context)
        else synthesize_accessors(class_name, node, context.module_call_body)
        end
      end

      def declare_define_method(class_name, node, context)
        name, body, parameters = UnitScan.define_method_unit(node)
        body_context = context.module_call_body
        return if name.nil? || body_context.nil?

        # The block runs on the special-variable slot of the body that calls `define_method`, shared by every sibling.
        add_unit(class_name, name, body_context, body, parameters, shared_slot: true)
      end

      # `attr_*` is a call on `self`, as `define_method` is, so it defines on the side `define_method` would:
      # the class's own accessors inside `class << self`, and none where no key names the owner.
      def synthesize_accessors(class_name, node, body_context)
        return if body_context.nil?

        singleton = body_context.singleton?
        separator = singleton ? "." : "#"
        symbol_arguments(node).each do |name|
          merge_unit("#{class_name}#{separator}#{name}", Summary.empty, []) unless node.name == :attr_writer
          next if node.name == :attr_reader

          merge_unit("#{class_name}#{separator}#{name}=", singleton ? SINGLETON_WRITER_SUMMARY : WRITER_SUMMARY, [])
        end
      end

      # The opaque-ancestry recordings the walk routes here; {AncestryRecorder} owns what they mean.
      def record_initialize_alias(prefix)
        @ancestry.record_initialize_alias(class_name_for(prefix))
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
