# frozen_string_literal: true

require "prism"
require_relative "../../reflection"
require_relative "../../rbs_extended"
require_relative "../../scope"
require_relative "../../scope/discovery_index"
require_relative "../../type"
require_relative "../diagnostic"
require_relative "receiver_predicates"
require_relative "rule_ids"
require_relative "source_arity"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `call.wrong-arity` (slice 7 phase 11): an explicit-receiver call whose positional
      # argument count falls outside the envelope of the declared signature, or (issue #992) of the project
      # `def` when no signature declares the method.
      #
      # The entry point is {.diagnostic}, called by `CheckRules.call_node_diagnostics`.
      # {.plain_positional_call?} is public because `CheckRules`' argument-type rule applies the same
      # call-shape test. It reads {ReceiverPredicates} and {SourceArity} (the project-`def` envelope walk),
      # and calls nothing in `CheckRules`.
      module WrongArity
        module_function

        # Slice 7 phase 11 — wrong-arity diagnostic. Fires when
        # an explicit-receiver `Prism::CallNode` resolves to a
        # method whose declared overloads do not admit the
        # supplied positional argument count (across all
        # overloads, see {#compute_arity_envelope}). One overload
        # with required keyword arguments or trailing positionals
        # leaves the whole method unchecked; calls with `*splat`, keyword, or
        # block-pass arguments are silently skipped to avoid
        # false positives. The check piggybacks on the same
        # scope-index lookup used by `undefined_method_diagnostic`;
        # it returns nil when the call's receiver / RBS coverage /
        # call shape disqualifies the rule.
        # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def diagnostic(path, call_node, facts, lexical_sites = nil)
          return nil if call_node.receiver.nil?
          return nil unless plain_positional_call?(call_node)

          scope = facts.scope
          return nil if scope.nil?

          # ADR-67 WD6b — an inferred-parameter receiver's type is an open-call-site lower bound; a wrong-arity
          # firing against it is an FP by construction. Decline.
          return nil if ReceiverPredicates.inferred_param_receiver?(call_node, scope)

          receiver_type = facts.receiver_type
          class_name = ReceiverPredicates.concrete_class_name(receiver_type)
          return nil if class_name.nil?

          # Issue #879 — the receiver whose surface `call.undefined-method` already refuses to enumerate.
          # Deciding an arity against a declaration this rule cannot prove the receiver actually runs is the
          # same unsoundness in signature form: the includer may declare the name with a wider arity, and
          # then the call is correct code.
          return nil if ReceiverPredicates.unenumerable_receiver_shape?(receiver_type, class_name, scope)

          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          # `Struct.new(:a, :b).new(...)` chained: the inner
          # `Struct.new(...)` is an anonymous Struct *subclass* whose
          # `.new` accepts any positional arity (one slot per member,
          # all defaulting to nil) — including zero. The receiver types
          # as `Singleton[Struct]` (so the call-site `.new` dispatches,
          # per the dispatcher's `struct_new_lift`), but validating that
          # `.new` against the real `Struct.new(*Symbol)` signature is a
          # false positive. Skip arity-checking the chained position.
          return nil if anonymous_struct_new_call?(call_node, class_name, kind)

          arity_envelope = arity_envelope_for(facts, class_name, kind)
          return nil if arity_envelope.nil?

          actual = (call_node.arguments&.arguments || []).size
          min, max, source_arity = arity_envelope
          if actual.between?(min, max)
            source_arity&.settle_by_definitions
            return nil
          end
          return nil if arity_report_withheld?(source_arity, class_name, call_node, scope, kind, lexical_sites)

          build_arity_diagnostic(path, call_node, class_name, min, max, actual)
        end

        # The declines `call.wrong-arity` asks only once the arity is out of the envelope.
        def arity_report_withheld?(source_arity, class_name, call_node, scope, kind, lexical_sites)
          # Issue #992 — a source envelope's remaining declines can only withhold, so they run only now.
          source_arity&.settle_by_walk
          return true if source_arity && !source_arity.authoritative?(class_name)

          ReceiverPredicates.refined_redefinition_in_effect?(class_name, call_node, scope, kind, lexical_sites)
        end

        # The `[min, max]` the call is checked against — a declared signature's, or (issue #992) the project
        # `def`'s own when no signature declares the method, with the {SourceArity} that found it as a third
        # element — or nil when neither may be trusted.
        #
        # Issue #991 — `discovered_method?` used to exempt the call outright before ever asking for a
        # declaration. `trustworthy_signature` is the same lookup `ArgumentType.diagnostic` treats as
        # authoritative over a source `def` (see its own comment beside that call), and the two rules must agree
        # on whose contract binds, so a declared method is checked against its declaration.
        def arity_envelope_for(facts, class_name, kind)
          receiver_type = facts.receiver_type
          call_node = facts.call_node
          scope = facts.scope
          if Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
            return nil unless ReceiverPredicates.definition_available?(receiver_type, class_name, scope)

            method_def = ReceiverPredicates.receiver_signature(facts)
            if method_def && !Rigor::RbsExtended.inferred_signature?(method_def)
              return nil if undeclared_constructor?(class_name, call_node, kind, method_def)

              return compute_arity_envelope(method_def)
            end
            return nil unless source_lane_open?(method_def, receiver_type, class_name, call_node, scope)
          end

          source_arity_envelope(class_name, call_node, scope, kind)
        end

        # Issue #992 — whether a class RBS knows may still be checked against its project `def`. Two lanes:
        #
        # - the member resolved and carries `%a{rigor:v1:inferred-signature}`: under ADR-93 the bundled
        #   `rigor-rbs-inline` plugin emits a full skeleton for EVERY `def` in a file carrying at least one
        #   annotation (#823), with every type slot defaulted, so nobody asserted anything about it. Its arity
        #   is NOT read here — the `def`'s envelope is, through the same {SourceArity} walk as a method with no
        #   member at all, so one `def` is never judged by two readings of its parameter list;
        # - no member resolved, and the class's declaration is the project's own `sig/`
        #   (`project_declared_class?`): a partial sidecar of a project class whose `def` lives in source.
        #
        # Everything else declines. A bundled declaration (core / stdlib / gem) describes a class the project
        # does not own, so a project `def` on it is an ADR-17 monkey-patch that another library may patch too;
        # a lookup that raised, or a name an open receiver only inherited (`trustworthy_signature` answered
        # nil for those while a raw lookup does not), is not "no member".
        def source_lane_open?(method_def, receiver_type, class_name, call_node, scope)
          return true if method_def

          ReceiverPredicates.lookup_method(receiver_type, class_name, call_node.name, scope).nil? &&
            Rigor::Reflection.project_declared_class?(class_name, scope: scope)
        end

        # Issue #992 — stage 1 of {SourceArity}: the nearest project definition's envelope, after the
        # receiver-level declines that need no walk. Stage 2 (`SourceArity#authoritative?`) runs only once the
        # count is known to fall outside it.
        def source_arity_envelope(class_name, call_node, scope, kind)
          return nil unless scope.discovered_parameter_envelopes.key?(Scope::DiscoveryIndex::ENVELOPE_PROJECT_WIDE)
          return nil if ReceiverPredicates.unbounded_receiver_surface?(class_name, scope)
          return nil if ReceiverPredicates.plugin_typed_call?(call_node, scope)
          # An instance of a project module is an instance of whatever includes it (#739's reasoning, which
          # `module_mixin_receiver?` can only apply to a module RBS declares).
          return nil if kind == :instance && project_module?(class_name, scope)
          return nil if project_module_class_receiver?(call_node, scope)

          arity = SourceArity.new(scope, call_node.name, kind)
          envelope = arity.owner_envelope(class_name)
          if envelope.nil? || envelope[2]
            envelope.nil? && arity.ambiguous? ? arity.settle_by_walk : arity.settle_by_definitions
            return nil
          end

          [envelope[0], envelope[1] || Float::INFINITY, arity]
        end

        # `self.class.f(1)` inside a project module's instance method: the engine types `self.class` as the
        # module's singleton, but at runtime it is the includer's class, whose class methods are its own. The
        # source-lane twin of {#mixin_self_class_receiver?}, which can only see a module RBS declares.
        def project_module_class_receiver?(call_node, scope)
          receiver = call_node.receiver
          return false unless receiver.is_a?(Prism::CallNode) && receiver.name == :class && receiver.arguments.nil?
          return false if receiver.receiver.nil?

          inner = ReceiverPredicates.concrete_class_name(scope.type_of(receiver.receiver))
          !inner.nil? && project_module?(inner, scope)
        end

        # Read off the table directly rather than through `Scope#parameter_envelopes_of`: a class does not turn
        # into a module without its declaration (and so the receiver's own typing) changing, so this answer
        # needs no ADR-46 class edge of its own.
        def project_module?(class_name, scope)
          bucket = scope.discovered_parameter_envelopes[class_name.to_s]
          !bucket.nil? && bucket.key?(Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK)
        end

        # Issue #917 — no loaded RBS declares a constructor for this class. The definition builder
        # synthesizes `.new` from the nearest `initialize` in the ancestry, and when nothing declares
        # one that is `BasicObject#initialize: () -> void`, so `.new` derives a nullary envelope that
        # is an artifact of the fallback rather than a statement about the class. `Gem::Specification`
        # is declared in full by the vendored rubygems sigs except for its constructor, and every
        # argument at the real one was reported. The rule needs "this class declares a nullary
        # constructor", and only a `defined_in` naming a class other than `BasicObject` is that
        # evidence — except on `BasicObject` and `Object` themselves, where the declaration is their
        # own and `.new` really does take no arguments.
        def undeclared_constructor?(class_name, call_node, kind, method_def)
          return false unless kind == :singleton && call_node.name == :new
          return false unless method_def.respond_to?(:defined_in)

          defined_in = method_def.defined_in
          return false unless defined_in.nil? || ReceiverPredicates.strip_root(defined_in.to_s) == "BasicObject"

          !%w[BasicObject Object].include?(ReceiverPredicates.strip_root(class_name))
        end

        # True for the outer `.new` of a chained `Struct.new(...).new`:
        # `class_name`/`kind` already pin the receiver to
        # `Singleton[Struct]`, and the receiver node is itself a
        # `Struct.new` (or `::Struct.new`) call — the anonymous subclass.
        def anonymous_struct_new_call?(call_node, class_name, kind)
          return false unless class_name == "Struct" && kind == :singleton
          return false unless call_node.name == :new

          receiver = call_node.receiver
          return false unless receiver.is_a?(Prism::CallNode) && receiver.name == :new

          inner = receiver.receiver
          return true if inner.is_a?(Prism::ConstantReadNode) && inner.name == :Struct

          # `::Struct.new(...).new` — a top-level constant path.
          inner.is_a?(Prism::ConstantPathNode) && inner.parent.nil? && inner.name == :Struct
        end

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
          # `RBS::Types::UntypedFunction` (used for `(?) ->`
          # untyped sigs) does not expose the per-arity
          # accessors. Treating it as ineligible is the
          # correct conservative move: an untyped function
          # has no static arity to enforce.
          return false unless function.respond_to?(:required_keywords)

          function.required_keywords.empty? && function.trailing_positionals.empty?
        end

        def build_arity_diagnostic(path, call_node, class_name, min, max, actual)
          range = min == max ? min.to_s : "#{min}..#{max}"
          method_label = "`#{call_node.name}' on #{class_name}"
          message = "wrong number of arguments to #{method_label} (given #{actual}, expected #{range})"
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_WRONG_ARITY,
            path: path,
            message: message,
            severity: :error,
            receiver_type: class_name,
            method_name: call_node.name.to_s
          )
        end

        private_class_method :arity_report_withheld?, :arity_envelope_for, :source_lane_open?, :source_arity_envelope,
                             :project_module_class_receiver?, :project_module?, :undeclared_constructor?,
                             :anonymous_struct_new_call?, :simple_positional?, :compute_arity_envelope,
                             :arity_eligible?, :build_arity_diagnostic
      end
    end
  end
end
