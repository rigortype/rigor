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
      # Issue #1362 adds a third carrier, a global still on its program-global seed, which joins the non-nil part of
      # the declared type of a global Ruby's own signatures declare with the file's writes (ADR-117 Decision point
      # 2: never warn that a value might deviate from the idiom). Its declared members are the declaration-sourced
      # part. The consumers judge such a value by the file's writes ({.written_type}, {.withholds_nil?}), and a
      # value that mixes it with something else without the declared members the file never writes
      # ({.declared_only_rejection?}), so a report the writes alone earn still fires.
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

        # Issue #1362 — true when every member of `type` that `expected` rejects is a declared member of a builtin
        # global this file writes and joins ({#declared_only_members}), so the rejection rests on the join alone. The
        # argument and return gates read it for a value that mixes such a global with something else
        # (`c ? $stdout : StringIO.new`), which the ADR-58 mark does not follow. It is a type-level reading: it also
        # withholds a rejection of such a member that comes from elsewhere in the file (`STDOUT` passed where a
        # `StringIO` is required, in a file that writes `$stdout`).
        #
        # Otherwise the value with those members taken out of every union inside it ({#without_declared_only}) is
        # handed to the block, which answers whether the caller's rule accepts it: the value as it was before the
        # join, one level into a container it builds as well (`[$stdout]` or `{ io: $stdout }` passed where an
        # `Array[StringIO]` is required), and with a `nil` the file writes judged as the rule judges a `nil`.
        def declared_only_rejection?(type, expected, scope)
          declared_only = declared_only_members(scope)
          return false if declared_only.empty?

          members = type.is_a?(Type::Union) ? type.members : [type]
          rejected = members.select { |member| Inference::Acceptance.accepts(expected, member, mode: :gradual).no? }
          return false if rejected.empty?
          return true if rejected.all? { |member| declared_only.include?(member) }

          stripped = without_declared_only(type, declared_only)
          !stripped.equal?(type) && yield(stripped)
        end

        # `type` with each member of `declared_only` taken out of every union in it, through tuples, hash shapes and
        # generic arguments; a union with nothing else left keeps its members. Answers `type` itself when nothing
        # was taken out.
        def without_declared_only(type, declared_only)
          case type
          when Type::Union then union_without_declared_only(type, declared_only)
          when Type::Tuple
            elements = type.elements.map { |element| without_declared_only(element, declared_only) }
            elements == type.elements ? type : Type::Combinator.tuple_of(*elements)
          when Type::HashShape
            pairs = type.pairs.transform_values { |value| without_declared_only(value, declared_only) }
            pairs == type.pairs ? type : rebuild_hash_shape(type, pairs)
          when Type::Nominal
            args = type.type_args.map { |arg| without_declared_only(arg, declared_only) }
            args == type.type_args ? type : Type::Combinator.nominal_of(type.class_name, type_args: args)
          else type
          end
        end

        def union_without_declared_only(union, declared_only)
          kept = union.members.reject { |member| declared_only.include?(member) }
          kept = union.members if kept.empty?
          rebuilt = kept.map { |member| without_declared_only(member, declared_only) }
          rebuilt == union.members ? union : Type::Combinator.union(*rebuilt)
        end

        def rebuild_hash_shape(shape, pairs)
          Type::Combinator.hash_shape_of(
            pairs, required_keys: shape.required_keys, optional_keys: shape.optional_keys,
                   read_only_keys: shape.read_only_keys, extra_keys: shape.extra_keys
          )
        end

        # For each builtin global this file writes and joins, the non-nil members of its declared type that the file's
        # writes to that global do not hold (`IO` after `$stdout = StringIO.new`, nothing after `$stderr = STDERR`),
        # gathered over the globals. A declared literal also counts in its class form, which a method called on the
        # joined union returns: `$VERBOSE.itself` reads `FalseClass | TrueClass` after `$VERBOSE = true`.
        def declared_only_members(scope)
          seeds = scope.discovery.program_global_seeds
          return NO_GLOBALS if seeds.empty?

          seeds.keys.flat_map do |name|
            written = type_members(scope.program_globals[name])
            type_members(scope.environment.global_for_name(name, builtin: true))
              .reject { |member| nil_bearing?(member) }
              .flat_map { |member| [member, *class_form(member)] }
              .reject { |member| written.include?(member) }
          end.uniq
        end

        def class_form(member)
          return NO_GLOBALS unless member.is_a?(Type::Constant)

          [Type::Combinator.nominal_of(member.value.class.name)]
        end

        def type_members(type)
          return NO_GLOBALS if type.nil?

          type.is_a?(Type::Union) ? type.members : [type]
        end

        def nil_bearing?(type)
          members = type.is_a?(Type::Union) ? type.members : [type]
          members.any? do |member|
            (member.is_a?(Type::Constant) && member.value.nil?) ||
              (member.is_a?(Type::Nominal) && member.class_name == "NilClass")
          end
        end
        private_class_method :nil_bearing?, :unparenthesised, :declared_only_members, :type_members, :class_form,
                             :without_declared_only, :union_without_declared_only, :rebuild_hash_shape
      end
    end
  end
end
