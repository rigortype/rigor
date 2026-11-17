# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../diagnostic"
require_relative "receiver_predicates"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `call.unresolved-toplevel` (ADR-34): an implicit-self call at toplevel scope whose name
      # resolves against no same-file `def`, `pre_eval:` patch, Kernel / Object RBS surface, `main` singleton
      # method or mixin of Object.
      #
      # The one entry point is {.diagnostic}, called by `CheckRules.call_node_diagnostics`. The module reads
      # {ReceiverPredicates} and calls nothing else in `CheckRules`; the eval-block ranges it consults are
      # computed once per file by `CheckRules.receiver_eval_block_ranges` and handed in. It also asks
      # {RebindingBlockCallees}.
      module UnresolvedToplevel
        module_function

        # ADR-34 — `call.unresolved-toplevel`. Fires on an
        # implicit-self call (no explicit receiver) at toplevel
        # scope (`scope.toplevel?`, i.e. outside any class /
        # module body) whose name does not resolve against:
        #
        # 1. A same-file toplevel `def` via
        #    {Scope#top_level_def_for}.
        # 2. The ADR-17 `ProjectPatchedMethods` registry under
        #    `(Object, name, :instance)` — projects declare
        #    their toplevel-injecting monkey-patches in
        #    `.rigor.yml`'s `pre_eval:` array as the canonical
        #    opt-out per ADR-34 WD2.
        # 3. The standard `Kernel` / `Object` private-method
        #    surface (`puts`, `p`, `require`, `loop`, `raise`,
        #    …) drawn from the loaded RBS environment.
        # 4. The private singleton methods of the top-level `main`
        #    object (`using`, `include`, `public`, `private`,
        #    `define_method`), read from RBS core's
        #    `RBS::Unnamed::TopLevelSelfClass`, plus
        #    `ruby2_keywords` (issue #1383).
        # 5. The instance methods of a module the project mixes
        #    into `Object` — a top-level `include M`, or an
        #    `include M` in `class Object` — or any call at all
        #    when such a module's surface is unknown (issue #1697).
        #
        # The rule deliberately does NOT generalise to
        # implicit-self calls inside `def` / `class` / `module`
        # bodies — ADR-24 WD3's lenient-on-unresolved default
        # stays in force there. ADR-24 WD4's gated class-body
        # diagnostic is a separate decision this ADR does not
        # open.
        #
        # Authored severity is `:warning`; the severity profile
        # remaps it (`strict` → `:error`, `balanced` →
        # `:warning`, `lenient` → `:off` / suppressed).
        def diagnostic(path, call_node, scope_index, eval_ranges = nil, lexical_sites = nil)
          return nil unless call_node.receiver.nil?

          scope = scope_index[call_node]
          return nil if scope.nil?
          return nil unless scope.toplevel?

          name = call_node.name
          return nil if scope.top_level_def_for(name)
          return nil if ReceiverPredicates.source_declared_method?(scope, "Object", name, :instance)
          return nil if Rigor::Reflection.instance_method_definition("Object", name, scope: scope)
          # Issue #1708 — `main` is an Object, so a `pre_eval:` patch on `Kernel` or `BasicObject` defines the name too.
          return nil if ReceiverPredicates.project_patched_through_ancestors?(scope, "Object", name, :instance)
          return nil if main_singleton_method?(name, scope)
          return nil if Inference::ObjectMixins.may_define?(scope, name, receiver: :implicit)
          # `Target.class_eval { def added = 1; def use_added = added }` files the defs on Target
          # but leaves the eval body with a nil `self_type`, so `toplevel?` still holds. An eval
          # body is morally a class body, so ADR-34 stays silent there — including on a genuinely
          # undefined name inside the block. Ranges are computed once per file.
          return nil if call_inside_receiver_eval_ranges?(eval_ranges, call_node)
          return nil if lexically_declined_toplevel_call?(call_node, scope, lexical_sites, scope_index)

          build_unresolved_toplevel_diagnostic(path, call_node)
        end

        # The `call.unresolved-toplevel` declines that read the file's syntax, asked last because they walk it.
        def lexically_declined_toplevel_call?(call_node, scope, lexical_sites, scope_index = nil)
          # ADR-121 WD7 — a refinement of `Object` (or one Rigor cannot read) in effect here may define the name.
          return true if ReceiverPredicates.refined_method_in_effect?("Object", call_node, scope, :instance,
                                                                      lexical_sites)
          return false if lexical_sites.nil?

          # Issue #1817 — a block handed to a project method that may `module_eval` / `instance_exec` it runs under
          # another `self`, so a call in it is not a top-level one ({RebindingBlockCallees}).
          RebindingBlockCallees.inside_rebound_block?(call_node, scope, lexical_sites.block_calls, scope_index)
        end

        # Issue #1383 — RBS core declares `main`'s private singleton methods on
        # `RBS::Unnamed::TopLevelSelfClass`, so the set follows RBS rather than a hand-kept
        # list. CRuby 4.0's `main` also has `ruby2_keywords`, which RBS does not declare.
        # rbs 3.x has no `TopLevelSelfClass`, so there only `ruby2_keywords` is covered.
        # A call inside a top-level block (`describe do include M end`) is judged here too;
        # silencing it is the cheaper error.
        MAIN_SINGLETON_CLASS_NAME = "RBS::Unnamed::TopLevelSelfClass"
        MAIN_SINGLETON_METHODS_MISSING_FROM_RBS = %i[ruby2_keywords].freeze
        private_constant :MAIN_SINGLETON_CLASS_NAME, :MAIN_SINGLETON_METHODS_MISSING_FROM_RBS

        def main_singleton_method?(name, scope)
          return true if MAIN_SINGLETON_METHODS_MISSING_FROM_RBS.include?(name)
          # `TopLevelSelfClass < Object`: when the project's own RBS broke `Object`, building it would only
          # fail again and report a second, unfixable class name beside `Object` (#696's report).
          return false if Rigor::Reflection.instance_definition("Object", scope: scope).nil?

          !Rigor::Reflection.instance_method_definition(MAIN_SINGLETON_CLASS_NAME, name, scope: scope).nil?
        end

        def call_inside_receiver_eval_ranges?(eval_ranges, call_node)
          return false if eval_ranges.nil? || eval_ranges.empty?

          loc = call_node.location
          eval_ranges.any? do |start_offset, end_offset|
            loc.start_offset >= start_offset && loc.end_offset <= end_offset
          end
        end

        def build_unresolved_toplevel_diagnostic(path, call_node)
          Diagnostic.from_message_loc(
            call_node,
            path: path,
            message: "unresolved toplevel call to `#{call_node.name}`. " \
                     "If a project file defines `#{call_node.name}` via a toplevel " \
                     "`def` or a monkey-patch on Object/Kernel, list that file in " \
                     "`.rigor.yml`'s `pre_eval:` (ADR-17) so the analyzer sees it.",
            severity: :warning,
            rule: RULE_UNRESOLVED_TOPLEVEL,
            method_name: call_node.name.to_s
          )
        end

        private_class_method :lexically_declined_toplevel_call?, :main_singleton_method?,
                             :call_inside_receiver_eval_ranges?, :build_unresolved_toplevel_diagnostic
      end
    end
  end
end
