# frozen_string_literal: true

require "prism"
require_relative "../../reflection"
require_relative "../../rbs_extended"
require_relative "../../inference/scope_indexer"
require_relative "../diagnostic"
require_relative "declaration_sourced_guard"
require_relative "override_support"
require_relative "replaced_singleton_defs"
require_relative "rule_ids"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `def.return-type-mismatch` (ADR-8): a `def` whose body's last expression types as
      # something its RBS-declared return cannot accept, with the declines the rule has accumulated (an
      # inherited declaration, a `refine` body, a replaced singleton def, a builtin global read, a `Dynamic`
      # body).
      #
      # The entry point is {.diagnostic}, called by `CheckRules.main_pass_node_diagnostics`. It reads
      # {OverrideSupport} (`declared_return_union`, `dynamic_top?` and `defined_on?`, which the override
      # rules call too) and {DeclarationSourcedGuard}, and calls nothing in `CheckRules`.
      module ReturnType
        module_function

        # Issue #1120, maintainer ruling a′ — a `def` in a `refine X do … end` body redefines X's method by design, so
        # X's declared return for the name is not its contract and a mismatch against it is not reported. Every other
        # check in the body stands. The refine-body test runs only once a mismatch would report, so a file pays the
        # {LexicalMethodSites} walk only then.
        def diagnostic(path, node, scope_index, lexical_sites)
          replaced = lexical_sites&.replaced_singleton_defs(scope_index)
          diagnostic = return_type_mismatch_diagnostic(path, node, scope_index, replaced)
          return diagnostic if diagnostic.nil? || lexical_sites.nil?

          lexical_sites.refinements.refinement_def?(node) ? nil : diagnostic
        end

        # ADR-8 § "`def.return-type-mismatch` rule" — flags a `def m(...) ... end` whose body's last
        # expression's type cannot satisfy the RBS-declared return type. Conservative envelope (v0.1.x
        # first cut):
        #
        # - Skips methods without an RBS declaration. The rule has no contract to compare against for
        #   source-only methods.
        # - Skips a `def` whose only declaration was resolved through an ANCESTOR. `Reflection`'s lookup
        #   reads the fully resolved method table, so a signature written about a base class answers for
        #   every subclass that inherits the name; comparing an override's body against it reports the
        #   override wrong for disagreeing with a contract that was never written about it (#744, and
        #   the four redmine sites in #856). ADR-35 already specifies this rule as comparing a method's
        #   OWN declared return, and the sibling override rules gate on `defined_on?` — this one did not.
        #   The inherited-declaration signal belongs to the ADR-35 family, which requires both sides
        #   authored. Decided in ADR-110 WD3.
        # - Skips methods whose enclosing `self` names no class (top-level methods land outside the rule).
        # - Skips methods whose body's last expression is absent or types as `Dynamic[top]` (the
        #   analyzer's fail-soft fallback) — emitting on `Dynamic[top]` would be noise.
        # - Compares the inferred body type against the declared return via `accepts?`:
        #     :yes   → silent
        #     :no    → emit at :error (severity_profile may re-stamp; default `balanced` keeps the
        #              authored severity).
        #     :maybe → silent (see {#compare_return}; ADR-8's `strict` promotion is deferred).
        def return_type_mismatch_diagnostic(path, def_node, scope_index, replaced_defs = nil)
          return nil if def_node.body.nil?

          last_expr = body_last_expression(def_node.body)
          return nil if last_expr.nil?

          inner_scope = scope_index[last_expr] || scope_index[def_node.body] || scope_index[def_node]
          return nil if inner_scope.nil?

          declared = declared_return_type(def_node, scope_index, replaced_defs)
          return nil if declared.nil?

          # Issue #1362 — a body that ends on a builtin global still on its declared seed, or on a local copied from
          # one, is judged by the file's writes to the global, as for an argument ({#single_argument_mismatch}).
          inferred = DeclarationSourcedGuard.written_type(last_expr, inner_scope) || inner_scope.type_of(last_expr)
          return nil if OverrideSupport.dynamic_top?(inferred)

          severity = compare_return(declared, inferred)
          return nil if severity.nil?
          return nil if declared_only_return?(last_expr, inferred, declared, inner_scope)

          build_return_type_mismatch_diagnostic(path, def_node, declared, inferred, severity)
        end

        # Issue #1362 — a body that ends on a value mixing a builtin global's seed with something else is judged
        # without the declared members the file never writes, as for an argument.
        def declared_only_return?(last_expr, inferred, declared, scope)
          return false unless DeclarationSourcedGuard.global_sources(last_expr, scope).empty?

          DeclarationSourcedGuard.declared_only_rejection?(inferred, declared, scope) do |stripped|
            compare_return(declared, stripped).nil?
          end
        end

        # The body of a `def` is the last `Prism::StatementsNode` child (or a single expression for
        # one-liner defs). Take the last statement; that's the implicit return.
        def body_last_expression(body)
          case body
          when Prism::StatementsNode then body.body.last
          when Prism::BeginNode then body_last_expression(body.statements)
          else body
          end
        end

        # Pulls the declared RBS return type for the def. The enclosing class name comes from the def's
        # scope's `self_type`; the method name is on the def itself. `def self.foo` is a singleton method
        # — dispatched through `Reflection.singleton_method_definition`; plain `def foo` uses
        # `instance_method_definition`. Method overloads contribute their union of declared return types
        # (any one of them satisfying the body silences the rule).
        #
        # v0.1.2 — when the RBS sig carries a `%a{rigor:v1:return: <refinement>}` annotation (recognised by
        # `RbsExtended.read_return_type_override`), the refinement carrier replaces the RBS-declared return
        # for this rule. Annotation-driven refinements — `non-empty-string`, `positive-int`,
        # `non-empty-array[Integer]`, etc. — are stricter than the underlying RBS class, so a body whose
        # inferred type the bare RBS sig would accept may still fail the refinement (e.g. `def name; "";
        # end` returns `Constant[""]`, accepted by `String` but rejected by `non-empty-string`).
        def declared_return_type(def_node, scope_index, replaced_defs = nil)
          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          side = if def_node.receiver.nil?
                   receiverless_def_side(scope, self_type.class_name, def_node)
                 else
                   receiver_def_side(scope, self_type.class_name, def_node)
                 end
          return nil if side.nil?

          method_def =
            if side == :instance
              Reflection.instance_method_definition(self_type.class_name, def_node.name, scope: scope)
            else
              Reflection.singleton_method_definition(self_type.class_name, def_node.name, scope: scope)
            end
          return nil if method_def.nil?
          return nil unless OverrideSupport.defined_on?(method_def, self_type.class_name)
          return nil if replaced_receiver_def?(def_node, replaced_defs)

          override = Rigor::RbsExtended.read_return_type_override(method_def, environment: scope.environment)
          return override if override

          OverrideSupport.declared_return_union(method_def, scope.environment)
        end

        # Which side a receiverless `def` defines, from the indexer's own record of THAT node: the instance table
        # holding it makes it an instance def, the singleton table (`class << self` bodies, and a `def` under
        # `Const.instance_eval` that the indexer attributes to the singleton) a singleton def. A node neither table
        # holds (a `def` in a block whose `self` the engine does not model, such as `E.class_eval do` inside
        # `class << self`, a redefinition a later `def` replaced) or both do is `nil`, and the caller declines: no
        # world is consulted, but the record cannot say which signature the body answers to.
        def receiverless_def_side(scope, class_name, def_node)
          instance = same_def_node?(scope.user_def_for(class_name, def_node.name), def_node)
          singleton = same_def_node?(scope.singleton_def_for(class_name, def_node.name), def_node)
          return :instance if instance && !singleton
          return :singleton if singleton && !instance

          nil
        end

        # Issue #3155 — a singleton def a later certain def replaced ({ReplacedSingletonDefs}). Asked only once the def
        # has a signature to answer to, so the file walk runs only then.
        def replaced_receiver_def?(def_node, replaced_defs)
          !def_node.receiver.nil? && replaced_defs&.replaced?(def_node)
        end

        # Issue #3155 — `def self.x`, or `def K.x` in `K`'s body, answers to K's singleton signature. A def on another
        # object (`def String.q`, `def obj.q` in a class body) or `def self.x` in a `class << self` body (a method of
        # the singleton class's own singleton) answers to none of K's: `nil`, and the caller declines.
        # {#declared_return_type} also declines, once a signature is found, a singleton def a later certain def of the
        # name in the same body replaced (`def K.w`; `def self.w`; {ReplacedSingletonDefs}). `def (self).x` reads as
        # `def self.x`; `K = self; def K.x` is not read.
        def receiver_def_side(scope, class_name, def_node)
          receiver = ReplacedSingletonDefs.unparenthesized(def_node.receiver)
          lexical_self = if receiver.is_a?(Prism::SelfNode)
                           !scope.singleton_class_body?
                         else
                           Inference::ScopeIndexer.def_receiver_targets_lexical_self?(receiver, class_name.split("::"))
                         end
          return nil unless lexical_self

          :singleton
        end

        # The tables hold the live node or one re-resolved from a `DefHandle`, so identity is the name and span.
        def same_def_node?(recorded, def_node)
          recorded.is_a?(Prism::DefNode) && recorded.name == def_node.name &&
            recorded.location.start_offset == def_node.location.start_offset &&
            recorded.location.end_offset == def_node.location.end_offset
        end

        # Returns the severity to emit at, or nil to stay silent. The first-cut implementation only fires
        # on proven (`:no`) mismatches; `:maybe` is treated as silent until the analyzer's narrowing
        # becomes precise enough to avoid noise on common patterns (`{}` → declared `Hash[K, V]`,
        # `Set.new` → declared `Set[Symbol]`, …). ADR-8's promise to emit on `:maybe` under
        # `severity_profile: strict` is deferred to a follow-up that lands together with the narrowing
        # precision improvements.
        def compare_return(declared, inferred)
          result = declared.accepts(inferred)
          return nil unless result.no?

          :error
        end

        def build_return_type_mismatch_diagnostic(path, def_node, declared, inferred, severity)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_RETURN_TYPE,
            path: path,
            message: "return-type mismatch on `#{def_node.name}': " \
                     "declared #{declared.describe(:short)}, inferred #{inferred.describe(:short)}",
            severity: severity,
            method_name: def_node.name.to_s
          )
        end

        private_class_method :return_type_mismatch_diagnostic, :declared_only_return?, :body_last_expression,
                             :declared_return_type, :receiverless_def_side, :replaced_receiver_def?,
                             :receiver_def_side, :same_def_node?, :compare_return,
                             :build_return_type_mismatch_diagnostic
      end
    end
  end
end
