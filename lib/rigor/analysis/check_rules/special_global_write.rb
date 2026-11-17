# frozen_string_literal: true

require "prism"
require_relative "../../reflection"
require_relative "../diagnostic"
require_relative "special_global_setters"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — the `global.*` rules for writes to Ruby's special globals (`$stdout`, `$,`, `$/`, `$;`
      # …): a write to a read-only global and a write whose literal value the setter's contract rejects. Owns
      # the census of what the program may answer to the setter's protocol.
      #
      # The one entry point is {.diagnostics}, called by `CheckRules.main_pass_node_diagnostics`. It reads
      # {ReceiverPredicates}, {SpecialGlobalSetters} and `Inference::GlobalWriteCensus`, and calls nothing
      # else in `CheckRules`.
      module SpecialGlobalWrite
        module_function

        # Issue #1367 (ADR-117 Decision point 1, WD2) — `global.write-type-mismatch` and `global.readonly-write`: a
        # write to a special global that the interpreter's setter rejects, so the write raises every time it runs.
        # The envelope is {SpecialGlobalSetters}: the setter, not the global's RBS declaration.
        #
        # - `global.readonly-write` needs no type. `$g = v`, `$g op= v` and a target of a multiple assignment
        #   (`$g, x = …`, `*$g`) always write, so a write to a read-only special raises.
        # - `global.write-type-mismatch` checks `$g = v` only when `v` is a literal node
        #   ({SpecialGlobalSetters.literal_class}), whose class the syntax fixes. Any other value is never reported,
        #   whatever its inferred type: a class RBS declares without `write` or `to_str` does not prove the object
        #   lacks it (a singleton `def`, an `extend`, or a run-time `alias to_str to_s`, as URI has).
        # - `$g ||= v` and `$g &&= v` write only when the current value is falsy (truthy), so neither rule checks
        #   them, nor a `for` index or a `rescue => $g` reference.
        # - A special that any project file aliases (`alias $stdout $out`, either side) is exempt from both.
        def diagnostics(path, node, scope_index, lexical_sites)
          case node
          when Prism::GlobalVariableWriteNode
            [readonly_global_write_diagnostic(path, node, scope_index) ||
              global_write_type_diagnostic(path, node, scope_index, lexical_sites)].compact
          when Prism::GlobalVariableOperatorWriteNode
            [readonly_global_write_diagnostic(path, node, scope_index)].compact
          when Prism::MultiWriteNode
            multi_write_global_targets(node).filter_map do |target|
              readonly_global_write_diagnostic(path, target, scope_index)
            end
          else
            []
          end
        end

        # The `GlobalVariableTargetNode`s a multiple assignment writes, through a splat (`*$g`) and nested
        # destructuring (`(a, $g), b = …`).
        def multi_write_global_targets(node)
          [*node.lefts, node.rest, *node.rights].flat_map do |target|
            case target
            when Prism::GlobalVariableTargetNode then [target]
            when Prism::SplatNode
              target.expression.is_a?(Prism::GlobalVariableTargetNode) ? [target.expression] : []
            when Prism::MultiTargetNode then multi_write_global_targets(target)
            else []
            end
          end
        end

        def readonly_global_write_diagnostic(path, node, scope_index)
          return nil unless SpecialGlobalSetters.read_only?(node.name)

          scope = scope_index[node]
          return nil if scope.nil? || global_aliased?(scope, node.name)

          location = node.respond_to?(:name_loc) ? node.name_loc : node.location
          Diagnostic.from_location(
            location,
            rule: RULE_GLOBAL_READONLY_WRITE,
            path: path,
            message: "`#{node.name}' is a read-only variable; this write raises NameError at runtime",
            severity: :error
          )
        end

        def global_write_type_diagnostic(path, node, scope_index, lexical_sites)
          contract = SpecialGlobalSetters.contract_for(node.name)
          return nil if contract.nil?

          class_name = SpecialGlobalSetters.literal_class(node.value)
          return nil if class_name.nil?

          scope = scope_index[node]
          return nil if scope.nil?
          return nil unless literal_rejected?(class_name, contract, node, scope, lexical_sites)
          return nil if global_aliased?(scope, node.name)

          build_global_write_type_diagnostic(path, node, contract, class_name)
        end

        # The project's {Inference::GlobalWriteCensus} with the `pre_eval:` files' own.
        def global_write_census(scope)
          census = scope.discovered_global_write_census
          pre_eval = scope.environment&.project_patched_methods&.write_census
          pre_eval.nil? || pre_eval.empty? ? census : census | pre_eval
        end

        # Whether any project or `pre_eval:` file aliases `name`, on either side, which can make it another variable.
        def global_aliased?(scope, name)
          record_global_census(Inference::GlobalWriteCensus.alias_entry(name))
          Inference::GlobalWriteCensus.aliased?(global_write_census(scope), name)
        end

        # Issue #2158 — a read of the whole-program census records the `global_census:` key of each entry it asks
        # about ({Inference::GlobalWriteCensus.dependency_key}): a file that starts or stops writing the entry (a `def
        # write`, an `alias $stdout $x`, a computed `define_method`) re-checks the write. A `pre_eval:` file moves the
        # snapshot's own fingerprint.
        def record_global_census(*entries)
          return unless DependencyRecorder.active?

          entries.each do |entry|
            DependencyRecorder.read_name(:global_census, Inference::GlobalWriteCensus.dependency_key(entry))
          end
        end

        # Whether the census holds any of `entries`, recording only what can flip the answer: the entries present
        # when it holds one (the answer stays true until every one of them vanishes, and another appearing changes
        # nothing), every entry when it holds none.
        #
        # This rests on an invariant: every census entry can only move a write toward being silenced, and a reported
        # write is always re-checked through `IncrementalSession#global_write_reporters`, so recording only the
        # present entries on a yes is sound. A future census entry that makes a write reported would break it, and
        # its reader would have to record every entry. Recording every entry on a no is defence in depth, since the
        # write that answer leaves reported re-checks through `global_write_reporters` anyway.
        def census_holds_any?(census, entries)
          present = entries.select { |entry| census.include?(entry) }
          record_global_census(*(present.empty? ? entries : present))
          !present.empty?
        end

        # A literal is rejected when its class is none the setter takes and, for a setter that also converts
        # (`to_str`, `to_int`) or asks for `write`, the literal's object cannot answer that method.
        def literal_rejected?(class_name, contract, node, scope, lexical_sites)
          return false if contract.accepts_class?(class_name)
          return true if contract.conversion.nil?

          !literal_may_answer?(class_name, contract.conversion, node, scope, lexical_sites)
        end

        # The escape hatches through which an object answers a method its class does not define: the setter's
        # `respond_to?` and implicit conversion both consult them.
        GLOBAL_WRITE_HATCHES = %i[method_missing respond_to_missing? respond_to?].freeze
        private_constant :GLOBAL_WRITE_HATCHES

        # Where RBS core declares the hatches every object inherits unchanged.
        DEFAULT_HATCH_OWNERS = %w[::BasicObject ::Kernel ::Object].freeze
        private_constant :DEFAULT_HATCH_OWNERS

        # Whether the literal's object may answer `method_name` after all:
        #
        # - RBS gives its class the method, or a hatch of its own (a project `sig/` reopening or `include` counts);
        # - the program defines the method or a hatch anywhere, in any spelling, on any receiver
        #   ({Inference::GlobalWriteCensus}): no census of where a definition lands can be complete
        #   (`class << nil`, `K = Integer; class K`, `[Integer].each { |k| k.define_method(:write) }`);
        # - an ancestor's surface is rewritten from outside (`Integer.include(M)`, `Object.include(M)`, a string
        #   `class_eval`: the `ENVELOPE_DYNAMIC_MARK`), or it or `Object` mixes in a module RBS does not rule out;
        # - for `write` only, a refinement that may add it is in effect at the write ({#refined_writer_in_effect?}).
        def literal_may_answer?(class_name, method_name, node, scope, lexical_sites)
          definition = Rigor::Reflection.instance_definition(class_name, scope: scope)
          return true if definition.nil?
          return true if definition.methods.key?(method_name) || overridden_hatch?(definition)

          ancestors = definition.ancestors.ancestors.to_set { |ancestor| ancestor.name.to_s.delete_prefix("::") }
          names = [method_name, *GLOBAL_WRITE_HATCHES]
          census = global_write_census(scope)
          program_may_answer?(ancestors, names, census, scope) ||
            (method_name == :write && refined_writer_in_effect?(census, node, scope, lexical_sites))
        end

        def overridden_hatch?(definition)
          GLOBAL_WRITE_HATCHES.any? do |name|
            method = definition.methods[name]
            method && !DEFAULT_HATCH_OWNERS.include?(method.defined_in.to_s)
          end
        end

        def program_may_answer?(ancestors, names, census, scope)
          defines = [Inference::GlobalWriteCensus::DEFINES_ANY, *names.map { |name| [:defines, name] }]
          return true if census_holds_any?(census, defines)

          dynamic_mark = Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK
          return true if ancestors.any? { |owner| scope.parameter_envelopes_of(owner).key?(dynamic_mark) }

          # One key for every top-level mixin, a deliberate trade-off: the reader asks about each, so a mixin
          # appearing or vanishing anywhere re-checks every write that reached this step.
          record_global_census(%i[main_mixin *])
          main_mixins = Inference::GlobalWriteCensus.main_mixins(census)
          main_mixins.any? { |mixin| rbs_mixin_may_answer?(mixin, names, scope) } ||
            mixin_may_answer?(ancestors, names, scope)
        end

        # A module an ancestor of the literal's class mixes in through a class body (`class Integer; include
        # Writable; end`), followed through the modules it mixes in in turn. A project module answers when its
        # surface is rewritten beyond literal names (a `send(:include, …)`, a non-constant mixin); its literal
        # definitions are the census's. Any other module answers when RBS does not know it or declares one of
        # `names`.
        def mixin_may_answer?(ancestors, names, scope)
          queue = ancestors.flat_map { |owner| scope.includes_of(owner) }
          seen = Set.new
          until queue.empty?
            mixin = queue.shift
            next unless seen.add?(mixin)

            bucket = scope.parameter_envelopes_of(mixin)
            if bucket.key?(Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK)
              return true if bucket.key?(Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)

              queue.concat(scope.includes_of(mixin))
            elsif rbs_mixin_may_answer?(mixin, names, scope)
              return true
            end
          end
          false
        end

        def rbs_mixin_may_answer?(mixin, names, scope)
          definition = Rigor::Reflection.instance_definition(mixin, scope: scope)
          definition.nil? || definition.methods.key?(names.first) || overridden_hatch?(definition)
        end

        # For `write` only: some refinement may add `write` (a `def`, `define_method` or `alias_method` in a `refine`
        # block, or an `import_methods`), and a `using` is in effect at the write. Which class it refines is not asked:
        # the target may be computed (`[Array].each { |k| refine(k) { … } }`) or a constant alias (`T = Array;
        # refine(T)`), so a refined `write` on any class declines every literal. `respond_to?(:write)` honours an
        # active refinement on Ruby 4.0.5; a refined `respond_to_missing?` or `respond_to?`, and every implicit
        # conversion, do not, so a refinement that adds only those leaves the write reported.
        def refined_writer_in_effect?(census, node, scope, lexical_sites)
          census_holds_any?(census, [Inference::GlobalWriteCensus::REFINES_ANY, %i[refines write]]) &&
            (lexical_sites.nil? || !scope.declared_refinements.empty? ||
              lexical_sites.refinements.any_at?(node.location.start_offset))
        end

        def build_global_write_type_diagnostic(path, node, contract, class_name)
          Diagnostic.from_name_loc(
            node,
            rule: RULE_GLOBAL_WRITE_TYPE_MISMATCH,
            path: path,
            message: "`#{node.name}' accepts only #{contract.accepts}; this write assigns " \
                     "#{SpecialGlobalSetters.literal_description(class_name)}, which raises TypeError at runtime",
            severity: :error
          )
        end

        private_class_method :multi_write_global_targets, :readonly_global_write_diagnostic,
                             :global_write_type_diagnostic, :global_write_census, :global_aliased?,
                             :record_global_census, :census_holds_any?, :literal_rejected?, :literal_may_answer?,
                             :overridden_hatch?, :program_may_answer?, :mixin_may_answer?, :rbs_mixin_may_answer?,
                             :refined_writer_in_effect?, :build_global_write_type_diagnostic
      end
    end
  end
end
