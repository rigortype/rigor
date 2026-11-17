# frozen_string_literal: true

require "prism"

require_relative "../../flow_contribution"
require_relative "../../rbs_extended"
require_relative "../../reflection"
require_relative "../../source/constant_path"
require_relative "../../type"
require_relative "../narrowing"

module Rigor
  module Inference
    class StatementEvaluator
      module DefArgumentsAndAssertions # rubocop:disable Metrics/ModuleLength
        module_function

        def evaluate_def_arguments(call_node, evaluator)
          args = call_node.arguments
          return unless args.respond_to?(:arguments)

          args.arguments.each do |arg|
            evaluator.eval_def(arg) if arg.is_a?(Prism::DefNode)
          end
        end

        # Recognises a small catalogue of RSpec matcher patterns as assert-shaped narrows on the local passed to
        # `expect(...)`. The pattern is matched purely on AST shape; no RBS for RSpec is required (and none is shipped
        # today).
        #
        # Recognised today:
        #
        #   expect(x).not_to(be_nil)
        #   expect(x).to_not(be_nil)
        #     → narrow `x` AWAY from `NilClass`.
        #
        #   expect(x).to(be_a(C))
        #   expect(x).to(be_kind_of(C))
        #   expect(x).to(be_an_instance_of(C))
        #   expect(x).to(be_instance_of(C))
        #     → narrow `x` to `C` (exact for the two
        #       `*instance_of` matchers, subtype-permitting
        #       otherwise).
        #
        # Anything else is silently passed through. Symmetric negative class assertions (`not_to be_a(C)`) and narrowing
        # TO `NilClass` are intentionally NOT modelled: they are rarely useful in practice and risk masking bugs if the
        # assertion later fails.
        def apply_rspec_matcher_narrowing(call_node, current_scope)
          narrow = rspec_matcher_narrowing_request(call_node)
          return current_scope if narrow.nil?

          local_name = narrow.fetch(:local)
          current_type = current_scope.local(local_name)
          return current_scope if current_type.nil?

          narrowed = apply_rspec_narrow(current_type, narrow, current_scope.environment)
          current_scope.with_local(local_name, narrowed)
        end

        # Decodes an `expect(x).<chain>` outer call into a narrowing request hash, or `nil` when the shape is not
        # recognised. The hash carries `:local` (the local name being narrowed) plus the narrowing parameters.
        def rspec_matcher_narrowing_request(call_node)
          local_name = rspec_expectation_target(call_node)
          return nil if local_name.nil?

          case call_node.name
          when :not_to, :to_not
            rspec_negative_narrow(call_node, local_name)
          when :to
            rspec_positive_narrow(call_node, local_name)
          end
        end

        def rspec_negative_narrow(call_node, local_name)
          return nil unless rspec_matcher_argument?(call_node, :be_nil)

          { local: local_name, kind: :not_class, class_name: "NilClass", exact: false }
        end

        def rspec_positive_narrow(call_node, local_name)
          matcher = rspec_matcher_node(call_node)
          return nil if matcher.nil?

          case matcher.name
          when :be_a, :be_kind_of
            rspec_be_a_narrow(matcher, local_name, exact: false)
          when :be_an_instance_of, :be_instance_of
            rspec_be_a_narrow(matcher, local_name, exact: true)
          end
        end

        # `be_a` / `be_kind_of` / `be_an_instance_of` accept a single class argument — either a `ConstantReadNode`
        # (`Integer`) or a `ConstantPathNode` (`Rigor::Type::Nominal`).
        def rspec_be_a_narrow(matcher, local_name, exact:)
          args = matcher.arguments&.arguments || []
          return nil unless args.size == 1

          class_name = Source::ConstantPath.qualified_name_or_nil(args.first)
          return nil if class_name.nil?

          { local: local_name, kind: :class, class_name: class_name, exact: exact }
        end

        def apply_rspec_narrow(current_type, narrow, environment)
          case narrow.fetch(:kind)
          when :not_class
            Narrowing.narrow_not_class(current_type, narrow.fetch(:class_name),
                                       exact: narrow.fetch(:exact), environment: environment)
          when :class
            Narrowing.narrow_class(current_type, narrow.fetch(:class_name),
                                   exact: narrow.fetch(:exact), environment: environment)
          end
        end

        # Returns the local name passed to `expect(...)` when the receiver chain matches `expect(<local>)` exactly, or
        # nil otherwise. Centralised so each per-matcher decoder can short-circuit on a non-matching outer call.
        def rspec_expectation_target(call_node)
          receiver = call_node.receiver
          return nil unless receiver.is_a?(Prism::CallNode) && receiver.name == :expect
          return nil unless receiver.receiver.nil?

          args = receiver.arguments&.arguments || []
          return nil unless args.size == 1

          target = args.first
          target.is_a?(Prism::LocalVariableReadNode) ? target.name : nil
        end

        def rspec_matcher_node(call_node)
          args = call_node.arguments&.arguments || []
          return nil unless args.size == 1

          matcher = args.first
          return nil unless matcher.is_a?(Prism::CallNode) && matcher.receiver.nil? && matcher.block.nil?

          matcher
        end

        # True when `call_node`'s sole argument is an implicit-self matcher call with the given name and no positional
        # arguments — used by the no-arg matchers (`be_nil`).
        def rspec_matcher_argument?(call_node, matcher_name)
          matcher = rspec_matcher_node(call_node)
          return false if matcher.nil?
          return false unless matcher.name == matcher_name

          matcher.arguments.nil? || matcher.arguments.arguments.empty?
        end

        # Slice 4b-2 (ADR-7 § "Slice 4-A/4-B") — applies the post-return facts the merger produces for an
        # `RBS::Extended`-annotated call. Reads through `RbsExtended.read_flow_contribution` so the bundle carries the
        # canonical `Rigor::FlowContribution::Fact` rows for `:always` assert directives (the slice-4a routing places
        # conditional asserts on `truthy_facts` / `falsey_facts`, which `Narrowing.predicate_scopes` consumes). Plugin
        # `:always` assertions are handled by the sibling `apply_plugin_assertions`, not this path.
        def apply_rbs_extended_assertions(call_node, current_scope, tracer)
          method_def = resolve_call_method(call_node, current_scope, tracer)
          return current_scope if method_def.nil?

          contribution = RbsExtended.read_flow_contribution(method_def, environment: current_scope.environment)
          return current_scope if contribution.nil?

          result = Rigor::FlowContribution::Merger.merge([contribution])
          post_return = result.post_return_facts
          return current_scope if post_return.empty?

          post_return.reduce(current_scope) do |scope_acc, fact|
            apply_post_return_fact(fact, call_node, scope_acc, method_def)
          end
        end

        # ADR-7 § "Slice 4-A" / T.bind priority slice 2 — applies the post-return facts plugin contributions produce.
        # This is the sibling of {apply_rbs_extended_assertions}: the carrier (`Rigor::FlowContribution::Fact`) and the
        # downstream narrowing path (`apply_post_return_fact` → `apply_self_post_return_fact`) are the same; only the
        # *source* of the bundle changes (RBS::Extended vs the registered plugins' `flow_contribution_for`).
        #
        # `:self`-targeted facts narrow `scope.self_type` for the surrounding scope. In a block body, the surrounding
        # scope is the block's own scope, so the narrowing applies to the rest of the block — exactly the contract
        # Sorbet's `T.bind(self, T)` commits to.
        #
        # `:parameter`-targeted facts only land when the called method has an authoritative RBS sig (via
        # `resolve_call_method`); plugins recognising their own synthetic call shapes (e.g. `T.assert_type!`) have no
        # method_def and the parameter facts silently skip — the plugin's own diagnostics_for_file path covers those
        # cases. The full plugin-side parameter-targeting story (PHPStan-style Type-Specifying Extensions on
        # plugin-recognised calls) lives behind a follow-up slice that introduces an `:argument_at` target kind.
        def apply_plugin_assertions(call_node, current_scope, tracer)
          registry = current_scope.environment&.plugin_registry
          return current_scope if registry.nil? || registry.empty?

          contributions = collect_plugin_contributions(registry, call_node, current_scope)
          return current_scope if contributions.empty?

          result = Rigor::FlowContribution::Merger.merge(contributions)
          post_return = result.post_return_facts
          return current_scope if post_return.empty?

          method_def = resolve_call_method(call_node, current_scope, tracer)
          post_return.reduce(current_scope) do |scope_acc, fact|
            apply_post_return_fact(fact, call_node, scope_acc, method_def)
          end
        end

        EMPTY_CONTRIBUTIONS = [].freeze
        private_constant :EMPTY_CONTRIBUTIONS

        # ADR-37 slice 2 / ADR-52 WD3 — gathers each plugin's post-return narrowing from the method-gated
        # `narrowing_facts` DSL, wrapped as a facts-only `FlowContribution`, swallowing per-plugin exceptions so a buggy
        # plugin can't abort the assertion path.
        #
        # Fast-exit guard: skip if no plugin declares a `narrowing_facts` rule, or if no registered method-name gate
        # matches the call. See `collect_gated_statement_contributions` for the full consultation.
        def collect_plugin_contributions(registry, call_node, current_scope)
          index = registry.contribution_index
          relevant = index.for_statement
          return EMPTY_CONTRIBUTIONS if relevant.empty?

          name = call_node.respond_to?(:name) ? call_node.name : nil
          return EMPTY_CONTRIBUTIONS unless index.statement_candidate?(name)

          collect_gated_statement_contributions(index, relevant, name, call_node, current_scope)
        end

        # ADR-37 slice 2 / ADR-52 WD1 — post-gate walk in registry order. Visits only plugins in `for_statement`
        # (declare a `narrowing_facts` rule), further gated by the method-name Set probe so the common no-candidate case
        # is a single lookup. Accumulates lazily; caller is read-only.
        def collect_gated_statement_contributions(index, relevant, name, call_node, current_scope)
          result = nil
          relevant.each do |plugin|
            next unless index.narrowing_facts_candidate_for?(plugin, name)

            facts = plugin.narrowing_facts_for(call_node: call_node, scope: current_scope)
            (result ||= []) << Rigor::FlowContribution.new(post_return_facts: facts) if facts && !facts.empty?
          rescue StandardError
            next
          end
          result || EMPTY_CONTRIBUTIONS
        end

        def resolve_call_method(call_node, current_scope, tracer)
          receiver_node = call_node.receiver
          receiver_type =
            if receiver_node
              current_scope.type_of(receiver_node, tracer: tracer)
            else
              current_scope.self_type
            end
          return nil if receiver_type.nil?

          class_name = assertion_class_name(receiver_type)
          return nil if class_name.nil?
          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: current_scope)

          if receiver_type.is_a?(Type::Singleton)
            Rigor::Reflection.singleton_method_definition(class_name, call_node.name, scope: current_scope)
          else
            Rigor::Reflection.instance_method_definition(class_name, call_node.name, scope: current_scope)
          end
        rescue StandardError
          nil
        end

        def assertion_class_name(receiver_type)
          case receiver_type
          when Type::Nominal, Type::Singleton then receiver_type.class_name
          end
        end

        # Slice 4b-2 — applies a single post-return Fact to the scope. Mirrors `Narrowing#apply_fact_to_scope`;
        # shares the narrowing logic via `Narrowing.narrow_for_fact` so the
        # predicate / assert / plugin paths all converge on the same hierarchy-aware narrowing rules.
        #
        # v0.1.8 Pillar 2 Slice 1 added the `:local` target_kind branch so plugins recognising bespoke call shapes
        # (`expect(x).to be_a(T)`) can directly narrow a named local in the surrounding scope, bypassing the
        # parameter-name lookup that requires an authoritative RBS sig on the called method (which RSpec matchers lack).
        def apply_post_return_fact(fact, call_node, current_scope, method_def)
          return apply_local_post_return_fact(fact, current_scope) if fact.target_kind == :local

          target_node = fact_target_node(fact, call_node, method_def)
          return apply_self_post_return_fact(fact, target_node, current_scope) if fact.target_kind == :self
          return current_scope unless target_node.is_a?(Prism::LocalVariableReadNode)

          local_name = target_node.name
          current_type = current_scope.local(local_name)
          return current_scope if current_type.nil?

          narrowed = Narrowing.narrow_for_fact(current_type, fact, current_scope.environment)
          current_scope.with_local(local_name, narrowed)
        end

        # v0.1.8 Pillar 2 Slice 1 — narrows the named local directly without consulting the call node's argument list.
        # The fact's `target_name` is the local-variable name as written in source. Silently no-ops when the local is
        # unbound in the current scope (the plugin's named local may have already gone out of scope when the
        # contribution fires).
        def apply_local_post_return_fact(fact, current_scope)
          local_name = fact.target_name
          current_type = current_scope.local(local_name)
          return current_scope if current_type.nil?

          narrowed = Narrowing.narrow_for_fact(current_type, fact, current_scope.environment)
          current_scope.with_local(local_name, narrowed)
        end

        # v0.1.1 Track 1 slice 3 — `assert self is T` post-return narrowing for the four supported receiver shapes
        # (mirrors `Narrowing#apply_self_fact`).
        def apply_self_post_return_fact(fact, receiver_node, current_scope)
          case receiver_node
          when nil, Prism::SelfNode
            current = current_scope.self_type
            return current_scope if current.nil?

            narrowed = Narrowing.narrow_for_fact(current, fact, current_scope.environment)
            current_scope.with_self_type(narrowed)
          when Prism::LocalVariableReadNode
            current = current_scope.local(receiver_node.name)
            return current_scope if current.nil?

            narrowed = Narrowing.narrow_for_fact(current, fact, current_scope.environment)
            current_scope.with_local(receiver_node.name, narrowed)
          when Prism::InstanceVariableReadNode
            current = current_scope.ivar(receiver_node.name)
            return current_scope if current.nil?

            narrowed = Narrowing.narrow_for_fact(current, fact, current_scope.environment)
            current_scope.with_ivar(receiver_node.name, narrowed)
          else
            current_scope
          end
        end

        # `:self` routes to the call receiver; otherwise we look up the matching positional argument by parameter name.
        def fact_target_node(fact, call_node, method_def)
          if fact.target_kind == :self
            call_node.receiver
          else
            lookup_post_return_arg(call_node, method_def, fact.target_name)
          end
        end

        def lookup_post_return_arg(call_node, method_def, target_name)
          # Plugin-source contributions arrive without an authoritative method_def (the plugin recognised the call shape
          # directly). Parameter-targeting falls back to "no narrow" in that case — the wider plugin-side parameter
          # mapping (`:argument_at`) is a follow-up slice.
          return nil if method_def.nil?

          arguments = call_node.arguments&.arguments || []
          # A `(?)` overload (`RBS::Types::UntypedFunction`, #1430) names no parameter and accepts any argument list,
          # so a call may reach it with the target's position holding anything: no overload proves the target.
          return nil unless method_def.method_types.all? { |mt| mt.type.respond_to?(:required_positionals) }

          method_def.method_types.each do |mt|
            params = mt.type.required_positionals + mt.type.optional_positionals
            index = params.find_index { |param| param.name == target_name }
            return arguments[index] if index && arguments[index]
          end
          nil
        end

        private_class_method :rspec_matcher_narrowing_request, :rspec_negative_narrow, :rspec_positive_narrow,
                             :rspec_be_a_narrow, :apply_rspec_narrow, :rspec_expectation_target, :rspec_matcher_node,
                             :rspec_matcher_argument?, :collect_plugin_contributions,
                             :collect_gated_statement_contributions, :resolve_call_method, :assertion_class_name,
                             :apply_post_return_fact, :apply_local_post_return_fact, :apply_self_post_return_fact,
                             :fact_target_node, :lookup_post_return_arg
      end
    end
  end
end
