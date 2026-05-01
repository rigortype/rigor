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
    # rubocop:disable Metrics/ModuleLength
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

          arity_diagnostic = wrong_arity_diagnostic(path, node, scope_index)
          diagnostics << arity_diagnostic if arity_diagnostic
        end
        diagnostics
      end

      # rubocop:disable Metrics/ClassLength
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

        # Returns a qualified class name for the in-scope check.
        # Nominal / Singleton carry a single-class identity
        # directly. Constant projects to its value's class.
        # Tuple projects to "Array" and HashShape to "Hash" so
        # arity / dispatch checks against the underlying class
        # still apply. Dynamic / Top / Union / Bot do not name a
        # single class and return nil to skip the rule.
        def concrete_class_name(type)
          case type
          when Type::Nominal, Type::Singleton then type.class_name
          when Type::Tuple then "Array"
          when Type::HashShape then "Hash"
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

        # Slice 7 phase 11 — wrong-arity diagnostic. Fires when
        # an explicit-receiver `Prism::CallNode` resolves to a
        # method whose declared overloads do not admit the
        # supplied positional argument count. The rule applies
        # ONLY to the simplest overload shape (single overload,
        # no `rest_positionals`, no keyword parameters, no
        # block-required positionals); calls with `*splat`
        # arguments, keyword arguments, or block-pass arguments
        # are silently skipped to avoid false positives. The
        # check piggybacks on the same scope-index lookup used
        # by `undefined_method_diagnostic`; it returns nil
        # when the call's receiver / RBS coverage / call shape
        # disqualifies the rule.
        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def wrong_arity_diagnostic(path, call_node, scope_index)
          return nil if call_node.receiver.nil?
          return nil unless plain_positional_call?(call_node)

          scope = scope_index[call_node]
          return nil if scope.nil?

          receiver_type = scope.type_of(call_node.receiver)
          class_name = concrete_class_name(receiver_type)
          return nil if class_name.nil?

          loader = scope.environment.rbs_loader
          return nil if loader.nil?
          return nil unless loader.class_known?(class_name)
          return nil unless definition_available?(loader, receiver_type, class_name)

          method_def = lookup_method(loader, receiver_type, class_name, call_node.name)
          return nil if method_def.nil? || method_def == true

          arity_envelope = compute_arity_envelope(method_def)
          return nil if arity_envelope.nil?

          actual = (call_node.arguments&.arguments || []).size
          min, max = arity_envelope
          return nil if actual.between?(min, max)

          build_arity_diagnostic(path, call_node, class_name, min, max, actual)
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def plain_positional_call?(call_node)
          arguments = call_node.arguments
          return true if arguments.nil?

          arguments.arguments.all? { |arg| simple_positional?(arg) }
        end

        def simple_positional?(arg)
          return false if arg.is_a?(Prism::SplatNode)
          return false if arg.is_a?(Prism::KeywordHashNode)
          return false if arg.is_a?(Prism::BlockArgumentNode)
          return false if arg.is_a?(Prism::ForwardingArgumentsNode)

          true
        end

        # Returns `[min, max]` positional-argument arity for the
        # method (across all overloads), or nil when the rule
        # does not apply. We disqualify only when the method
        # uses required keyword arguments (which the caller MUST
        # pass at the call site, and our plain-positional check
        # would not have caught) or trailing positionals (rare,
        # complex). `optional_keywords` and `rest_keywords` do
        # NOT affect positional arity. `rest_positionals` raises
        # `max` to `Float::INFINITY`.
        def compute_arity_envelope(method_def)
          mins = []
          maxes = []
          method_def.method_types.each do |mt|
            function = mt.type
            return nil unless arity_eligible?(function)

            min_arity = function.required_positionals.size
            max_arity =
              if function.rest_positionals
                Float::INFINITY
              else
                min_arity + function.optional_positionals.size
              end
            mins << min_arity
            maxes << max_arity
          end
          return nil if mins.empty?

          [mins.min, maxes.max]
        end

        def arity_eligible?(function)
          function.required_keywords.empty? && function.trailing_positionals.empty?
        end

        # rubocop:disable Metrics/ParameterLists
        def build_arity_diagnostic(path, call_node, class_name, min, max, actual)
          location = call_node.message_loc || call_node.location
          range = min == max ? min.to_s : "#{min}..#{max}"
          method_label = "`#{call_node.name}' on #{class_name}"
          message = "wrong number of arguments to #{method_label} (given #{actual}, expected #{range})"
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: message,
            severity: :error
          )
        end
        # rubocop:enable Metrics/ParameterLists

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
      # rubocop:enable Metrics/ClassLength
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
