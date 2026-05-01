# frozen_string_literal: true

require "prism"

require_relative "../source/node_walker"
require_relative "../type"
require_relative "diagnostic"

module Rigor
  module Analysis
    # First-preview catalogue of `rigor check` diagnostic rules.
    #
    # The rules are intentionally narrow: they fire ONLY when the
    # engine is confident enough to make a useful claim, and they
    # MUST NOT raise on unrecognised AST shapes, RBS gaps, or
    # missing scope information. Each rule consumes the per-node
    # scope index produced by
    # `Rigor::Inference::ScopeIndexer.index` and yields zero or
    # more `Rigor::Analysis::Diagnostic` values.
    #
    # The first shipped rule, `UndefinedMethodOnTypedReceiver`,
    # flags an explicit-receiver `Prism::CallNode` whose receiver
    # statically resolves to a `Type::Nominal` or `Type::Singleton`
    # known to the analyzer's RBS environment AND whose method
    # name does not appear on that class's instance / singleton
    # method table. This is the canonical "type check" signal
    # ("Foo has no method bar"), but it explicitly does NOT fire
    # for:
    #
    # - implicit-self calls (no `node.receiver`) — too noisy
    #   without per-method RBS for every helper in the class.
    # - dynamic / unknown receivers (`Dynamic[T]`, `Top`, `Union`)
    #   — by definition we cannot enumerate the method set.
    # - shape carriers (`Tuple`, `HashShape`, `Constant`) — their
    #   dispatch goes through `ShapeDispatch` / `ConstantFolding`
    #   which the rule does not yet model.
    # - receivers whose class name is NOT registered in the
    #   loader (RBS-blind environments, unknown stdlib).
    #
    # The above list is the deliberate conservative envelope of
    # the first preview; later slices broaden it.
    module CheckRules
      module_function

      # Yields diagnostics for every unrecognised method call on
      # a typed receiver in `root`'s subtree. The caller MUST
      # have already produced `scope_index` through
      # `Rigor::Inference::ScopeIndexer.index(root, default_scope:)`.
      #
      # @param path [String] used to populate
      #   `Diagnostic#path`; the rule does not open files.
      # @param root [Prism::Node]
      # @param scope_index [Hash{Prism::Node => Rigor::Scope}]
      # @return [Array<Rigor::Analysis::Diagnostic>]
      def diagnose(path:, root:, scope_index:)
        diagnostics = []
        Source::NodeWalker.each(root) do |node|
          next unless node.is_a?(Prism::CallNode)

          diagnostic = undefined_method_diagnostic(path, node, scope_index)
          diagnostics << diagnostic if diagnostic
        end
        diagnostics
      end

      class << self
        private

        def undefined_method_diagnostic(path, call_node, scope_index) # rubocop:disable Metrics/CyclomaticComplexity
          return nil if call_node.receiver.nil?

          scope = scope_index[call_node]
          return nil if scope.nil?

          receiver_type = scope.type_of(call_node.receiver)
          class_name = concrete_class_name(receiver_type)
          return nil if class_name.nil?

          loader = scope.environment.rbs_loader
          return nil if loader.nil?
          return nil unless loader.class_known?(class_name)

          # When the loader cannot build a class definition for a
          # name it nominally knows (constant-decl aliases such
          # as `YAML` → `Psych`, or RBS-build failures for
          # malformed signatures), we cannot enumerate methods
          # so we MUST NOT emit a false positive. Skip the rule
          # in that case.
          return nil unless definition_available?(loader, receiver_type, class_name)

          method_def = lookup_method(loader, receiver_type, class_name, call_node.name)
          return nil if method_def

          build_undefined_method_diagnostic(path, call_node, receiver_type)
        end

        # Restrict to Nominal / Singleton / Constant — those carry
        # a single-class identity. Tuple / HashShape have their
        # own dispatch path that the loader-only check would
        # ignore; Dynamic / Top / Union / Bot do not name a
        # single class. Returns the qualified class name for the
        # in-scope check, or nil to skip the rule.
        def concrete_class_name(type)
          case type
          when Type::Nominal, Type::Singleton then type.class_name
          when Type::Constant then constant_class_name(type.value)
          end
        end

        CONSTANT_CLASSES = {
          Integer => "Integer", Float => "Float", String => "String",
          Symbol => "Symbol", Range => "Range",
          TrueClass => "TrueClass", FalseClass => "FalseClass",
          NilClass => "NilClass"
        }.freeze
        private_constant :CONSTANT_CLASSES

        def constant_class_name(value)
          CONSTANT_CLASSES.each { |klass, name| return name if value.is_a?(klass) }
          nil
        end

        def definition_available?(loader, receiver_type, class_name)
          if receiver_type.is_a?(Type::Singleton)
            !loader.singleton_definition(class_name).nil?
          else
            !loader.instance_definition(class_name).nil?
          end
        rescue StandardError
          false
        end

        def lookup_method(loader, receiver_type, class_name, method_name)
          if receiver_type.is_a?(Type::Singleton)
            loader.singleton_method(class_name: class_name, method_name: method_name)
          else
            loader.instance_method(class_name: class_name, method_name: method_name)
          end
        rescue StandardError
          # The loader is best-effort and may raise on malformed
          # RBS. Treat any failure as "method exists" so we do
          # NOT emit a false positive when our knowledge of the
          # receiver class is structurally incomplete.
          true
        end

        def build_undefined_method_diagnostic(path, call_node, receiver_type)
          location = call_node.message_loc || call_node.location
          rendered_receiver = receiver_type.describe
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: "undefined method `#{call_node.name}' for #{rendered_receiver}",
            severity: :error
          )
        end
      end
    end
  end
end
