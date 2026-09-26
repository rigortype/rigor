# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      # ADR-58 WD1 — the shared "is this value's optionality declaration-sourced?" predicate.
      #
      # A `nil` whose only provenance is a declaration (the class-ivar index seed of a ctor `@x = nil`, a
      # non-definitely-assigned ivar read) is real type information but not diagnostic fuel: the working
      # program's cross-method invariant is assumed per the robustness principle ([ADR-5]). Every negative rule
      # that would fire *because of* such a nil must therefore consult the same provenance question, and get the
      # same answer.
      #
      # Before issue #324 each rule spelled the lookup itself, and they drifted: `call.possible-nil-receiver`
      # read the `:local` mark (so `r = @right; r.key` was excused — ADR-58's own motivating shape), while both
      # `call.argument-type-mismatch` gates opened by requiring a literal `Prism::InstanceVariableReadNode`, so
      # `c = @count; sink.take_int(c)` fired on the same value with the same provenance. This module is that one
      # question, asked in one place.
      #
      # **The mark is deliberately NOT transitive.** `Scope#with_declaration_sourced_local`
      # ({Inference::StatementEvaluator#eval_local_write}) stamps `:local` only when the RHS is a *pure read of a
      # currently declaration-sourced ivar*, so a second hop (`c = @count; d = c`) and an `||=` rewrite land on
      # the plain `with_local` path and carry no mark.
      #
      # A branch join is NOT one of those cases, contrary to what this comment claimed when it landed: both
      # arms of `if c then r = @count else r = @count end` stamp `(:local, :r)`, and `join_declaration_sourced`
      # INTERSECTS, so the mark survives. Only an *asymmetric* join drops it, and by that intersection rather
      # than by reaching `with_local`. The normative statement — establishment, drop, join and the full list of
      # unmarked shapes, each verified against the implementation — is
      # `docs/internal-spec/inference-engine.md` § "Declaration-sourced provenance mark (ADR-58)"; keep this
      # comment subordinate to it.
      #
      # So `marked?` matches exactly the node shapes the scope actually models and invents no propagation of its
      # own; anything flow-live keeps firing.
      #
      # Issue #1362 adds a third carrier, a global still on its program-global seed, which joins the declared type
      # of a global Ruby's own signatures declare with the file's writes (ADR-117 Decision point 2: never warn that
      # a value might deviate from the idiom). Its declared members, `nil` among them, are the declaration-sourced
      # part. A consumer that can compare against the file's writes does so ({.global_sources},
      # {.withholds_nil?}), so a report the writes alone earn still fires.
      module DeclarationSourcedGuard
        NO_GLOBALS = [].freeze
        private_constant :NO_GLOBALS

        module_function

        # True when `node` is a direct read of a binding whose optionality is purely declaration-sourced. Any
        # flow-live touch (a method-local `@x = nil` write, a failed-guard narrowing, a rebinding local write)
        # drops the mark upstream, so this returns false there and the caller fires exactly as before.
        def marked?(node, scope)
          case node
          when Prism::InstanceVariableReadNode then scope.declaration_sourced?(:ivar, node.name)
          when Prism::LocalVariableReadNode then scope.declaration_sourced?(:local, node.name)
          when Prism::GlobalVariableReadNode then scope.declaration_sourced?(:global, node.name)
          else false
          end
        end

        # The globals whose declared seeds `node` still reads, empty for none: a read of a marked global, or of a
        # local copied from one or more (`sep = $/`, `Scope#declaration_sourced_global_copies`), bare or in
        # parentheses (`($stdout)`).
        def global_sources(node, scope)
          node = unparenthesised(node)
          case node
          when Prism::GlobalVariableReadNode
            scope.declaration_sourced?(:global, node.name) ? [node.name] : NO_GLOBALS
          when Prism::LocalVariableReadNode
            scope.declaration_sourced_global_copies(node.name)
          else NO_GLOBALS
          end
        end

        # The globals a local written from `value` copies the declared seeds of, empty for none: a read of a marked
        # global, bare or in parentheses (`sep = ($/)`), or a bare read of a local that copies some (`s = sep`).
        # Unlike an ivar copy's, this mark follows bare local-to-local copies; a method result (`$/.dup`) or a
        # container element (`[$/].each { |s| … }`) carries none, as ADR-58's one-hop boundary has it.
        def copied_globals(value, scope)
          return scope.declaration_sourced_global_copies(value.name) if value.is_a?(Prism::LocalVariableReadNode)

          read = unparenthesised(value)
          return NO_GLOBALS unless read.is_a?(Prism::GlobalVariableReadNode) &&
                                   scope.declaration_sourced?(:global, read.name)

          [read.name]
        end

        # `node` with its enclosing parentheses taken off while they hold a single expression.
        def unparenthesised(node)
          while node.is_a?(Prism::ParenthesesNode)
            body = node.body
            break unless body.is_a?(Prism::StatementsNode) && body.body.size == 1

            node = body.body.first
          end
          node
        end

        # The union of the file's own writes to the globals `node` reads the seeds of ({.global_sources}), or nil.
        def written_type(node, scope)
          sources = global_sources(node, scope)
          return nil if sources.empty?

          written = sources.map { |source| scope.program_globals[source] }
          written.include?(nil) ? nil : Type::Combinator.union(*written)
        end

        # True when a `nil` in `node`'s type is not diagnostic fuel: for a global's seed or its copy, when the file
        # never writes `nil` to the global, so the declaration alone contributes it; otherwise when `node` carries
        # the ADR-58 mark.
        def withholds_nil?(node, scope)
          written = written_type(node, scope)
          return marked?(node, scope) if written.nil?

          !nil_bearing?(written)
        end

        # True when the file's writes to the global `node` reads its seed from would pass where `expected` is
        # required, so a rejection rests on the declared members alone. `expected` is asked the question the
        # caller's rule asks of the whole type, gradually.
        def written_accepted?(node, scope, expected)
          written = written_type(node, scope)
          return false if written.nil?

          !Inference::Acceptance.accepts(expected, written, mode: :gradual).no?
        end

        def nil_bearing?(type)
          members = type.is_a?(Type::Union) ? type.members : [type]
          members.any? do |member|
            (member.is_a?(Type::Constant) && member.value.nil?) ||
              (member.is_a?(Type::Nominal) && member.class_name == "NilClass")
          end
        end
        private_class_method :nil_bearing?, :unparenthesised
      end
    end
  end
end
