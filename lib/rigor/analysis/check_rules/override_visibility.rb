# frozen_string_literal: true

require_relative "../../inference/definer_resolution"
require_relative "../diagnostic"
require_relative "override_support"
require_relative "rule_ids"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `def.override-visibility-reduced` (ADR-35 slice 1): an instance-method override that
      # reduces the visibility it inherits from a project ancestor.
      #
      # The one entry point is {.diagnostic}, called by `CheckRules.main_pass_node_diagnostics`. It reads
      # {OverrideSupport} and `Inference::DefinerResolution` and calls nothing else in `CheckRules`.
      module OverrideVisibility
        module_function

        # ADR-35 slice 1 — the public > protected > private ordering used to decide whether an override reduces
        # visibility. The override rules' ancestor walk is bounded by `Scope::ANCESTOR_WALK_LIMIT`, the
        # resolution chain's.
        VISIBILITY_RANK = { public: 2, protected: 1, private: 0 }.freeze

        # The names CRuby makes private on every non-singleton `def` whatever section it is written in
        # (`vm_method.c` `rb_method_entry_make`), so a source-discovered visibility for them is not the
        # runtime one and `def.override-visibility-reduced` cannot prove a reduction.
        IMPLICITLY_PRIVATE_METHODS = (OverrideSupport::LIFECYCLE_HOOKS + %i[respond_to_missing?]).freeze

        # ADR-35 slice 1 — `def.override-visibility-reduced`. The Liskov signature rule for visibility: an
        # instance-method override MUST NOT reduce the visibility it inherits (public → protected/private,
        # or protected → private), because a caller holding the supertype that invokes the method breaks
        # when handed the subtype.
        #
        # Slice-1 scope (ADR-35 WD1, visibility carve-out): both the override and the shadowed method must
        # have a STATICALLY OBSERVABLE visibility. The override's visibility is read from the
        # source-discovered table; the parent is resolved against the project-discovered ancestor chain
        # (user-source classes / modules only — RBS-known ancestors, whose accessibility RBS models as
        # public/private only, are a deferred follow-on). When either side is not observable the rule stays
        # silent.
        def diagnostic(path, def_node, scope_index)
          return nil unless def_node.receiver.nil? # instance methods only
          return nil if IMPLICITLY_PRIVATE_METHODS.include?(def_node.name)

          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          class_name = self_type.class_name.to_s
          method_name = def_node.name

          override_visibility = scope.discovered_method_visibility(class_name, method_name)
          return nil if override_visibility.nil?
          # Issue #2013 — a contested slot (a later `define_method` or alias gave the name another visibility, or a
          # write the walk cannot place) proves no reduction.
          return nil if scope.discovery.contested?(:discovered_method_visibilities, [class_name, method_name])

          parent = nearest_ancestor_visibility(scope, class_name, method_name)
          return nil if parent.nil?

          parent_class, parent_visibility = parent
          # Unknown ancestor visibility (e.g. the defining file was not in the analyzed set) → cannot
          # prove a reduction, stay silent.
          return nil if parent_visibility.nil?
          return nil unless visibility_reduced?(parent_visibility, override_visibility)
          # Issue #1569 — a module function's instance copy is private because `module_function` made it so; the
          # author's intent is the public singleton copy, so that reduction is not reported.
          return nil if scope.module_function_def?(class_name, def_node)

          build_override_visibility_diagnostic(
            path, def_node, parent_class, parent_visibility, override_visibility
          )
        end

        # Returns true when `override_visibility` is strictly more restrictive than `parent_visibility`
        # under the public > protected > private ordering.
        #
        # The nil guard below is defence, not dead code. `VISIBILITY_RANK` is a closed literal hash read
        # with a dynamic key, so a symbol outside the table reads as nil at runtime. The engine folds that
        # read to the nil-free value union `0 | 1 | 2`, which `internal-spec/inference-engine.md` declares
        # OPTIMISTIC rather than proof — and since issue #313 that mark survives the `.nil?` fold and the
        # `||` composition, so no suppression directive is needed here.
        def visibility_reduced?(parent_visibility, override_visibility)
          parent_rank = VISIBILITY_RANK[parent_visibility]
          override_rank = VISIBILITY_RANK[override_visibility]
          return false if parent_rank.nil? || override_rank.nil?

          override_rank < parent_rank
        end

        # `[defining_class, visibility]` for the nearest user-source ancestor that defines an instance
        # method `method_name`, or nil.
        def nearest_ancestor_visibility(scope, class_name, method_name)
          from = OverrideSupport.overridden_ancestors_start(scope, class_name)
          return nil if from.nil?

          case Inference::DefinerResolution.resolve(scope, class_name, method_name, :instance,
                                                    question: :override, from: from) do |ancestor|
                 # Stop at the nearest ancestor that DEFINES the method; its visibility may be nil (unknown) —
                 # the caller treats unknown as "cannot prove a reduction" and stays silent. Never fabricate
                 # `:public` from a missing entry (that produced a large false-positive cluster on
                 # cross-file Rails concerns). The `:unrecorded` marker stands for that nil in the answer.
                 next unless scope.user_def_for(ancestor, method_name)

                 scope.discovered_method_visibility(ancestor, method_name) || :unrecorded
               end
          in Inference::DefinerResolution::Known(answer: [owner, visibility])
            [owner, visibility == :unrecorded ? nil : visibility]
          in Inference::DefinerResolution::UNKNOWN # the case/in contract needs one arm per answer
            nil
          in Inference::DefinerResolution::ABSENT # rubocop:disable Lint/DuplicateBranch -- see above
            nil
          end
        end

        def build_override_visibility_diagnostic(path, def_node, parent_class, parent_visibility, override_visibility)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_VISIBILITY_REDUCED,
            path: path,
            message: "visibility of `#{def_node.name}' reduced from #{parent_visibility} to " \
                     "#{override_visibility} (overrides #{parent_class}##{def_node.name}); " \
                     "breaks substitutability",
            severity: :warning,
            method_name: def_node.name.to_s
          )
        end

        private_class_method :visibility_reduced?, :nearest_ancestor_visibility,
                             :build_override_visibility_diagnostic
      end
    end
  end
end
