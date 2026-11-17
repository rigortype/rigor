# frozen_string_literal: true

require "prism"

require_relative "../../reflection"
require_relative "../../type"
require_relative "../definer_resolution"
require_relative "../error_info"
require_relative "../method_dispatcher"
require_relative "../multi_target_binder"
require_relative "../narrowing"

module Rigor
  module Inference
    class StatementEvaluator
      module PatternBindings # rubocop:disable Metrics/ModuleLength
        module_function

        # --------------------------------------------------------------- rescue variable binding helpers
        # ---------------------------------------------------------------

        # Returns `scope` extended with the rescue reference variable bound to the exception instance type. Leaves scope
        # unchanged when the node carries no reference (bare `rescue` without `=> var`). An index-target reference
        # (`rescue => h[:e]`) stores the exception through `[]=` instead, so its receiver widens with the exception
        # instance type as the stored value, exactly as `rescue => e; h[:e] = e` widens it.
        #
        # Issue #1360 — with or without a reference, the clause runs with `$!` bound to the exception it rescued, `$@`
        # to its backtrace and `$?` unbound ({ErrorInfo.rescue_entry}); {#eval_begin_node} restores `$!` and `$@` once
        # the `begin` exits.
        def bind_rescue_reference(rescue_node, scope, evaluator)
          exception_type = rescue_exception_type(rescue_node, scope, evaluator)
          ref = rescue_node.reference
          reference = ref.name if ref.is_a?(Prism::LocalVariableTargetNode)
          scope = ErrorInfo.rescue_entry(scope, exception_type, rescue_node.statements, reference)
          case ref
          when Prism::LocalVariableTargetNode
            scope.with_local(ref.name, exception_type)
          when Prism::InstanceVariableTargetNode
            # Issue #1446 — `rescue => @io` writes the ivar, which ends a class guard's narrowing of it, and `rescue =>
            # $out` the global, which ends any guard's narrowing of it.
            scope.with_ivar(ref.name, exception_type).without_ivar_guard(ref.name)
          when Prism::GlobalVariableTargetNode
            scope.with_global(ref.name, exception_type)
          when Prism::ClassVariableTargetNode
            scope.with_cvar(ref.name, exception_type)
          when Prism::IndexTargetNode
            evaluator.widen_index_target(ref, exception_type, scope, type_scope: scope)
          when Prism::CallTargetNode
            # Issue #3205 — `rescue => x.r` calls `r=` on `x`, as `for x.r in` does (issue #2693).
            evaluator.widen_attribute_write(ref.receiver, ref.name, scope)
          else
            scope
          end
        end

        # Derives the exception instance type for a `RescueNode` ({ErrorInfo.rescue_exception_type}): `StandardError`
        # for a bare `rescue`, else the union of the named classes' instances, with `Dynamic[top]` for one that does not
        # resolve to a `Singleton`.
        def rescue_exception_type(rescue_node, scope, evaluator)
          ErrorInfo.rescue_exception_type(rescue_node) do |exception_node|
            evaluator.sub_eval(exception_node, scope).first
          end
        end

        # --------------------------------------------------------------- `case/in` pattern variable binding helpers
        # ---------------------------------------------------------------

        # Builds the entry scope for an `in` branch by injecting every variable captured by the pattern as a local
        # binding. `subject_type` is the type of the `case` subject — nil when the `case` carries no predicate, which
        # leaves every binding at the `Dynamic[top]` floor — and `subject_node` the subject expression, which the
        # `deconstruct` / `deconstruct_keys` dispatch reads for its freshness gate.
        def apply_in_pattern_bindings(subject_type, subject_node, pattern, scope, evaluator)
          bindings = collect_in_pattern_bindings(subject_type, pattern, scope, evaluator, subject_node: subject_node)
          bound = bindings.reduce(scope) { |s, (name, type)| s.with_local(name, type) }
          marked = subject_node.is_a?(Prism::LocalVariableReadNode) && scope.gradual_narrowing?(subject_node.name)
          mark_gradual_class_capture(subject_type, pattern, bound, marked: marked)
        end

        # Issue #2656 — `in C => y` over a `Dynamic` subject binds `y` to `C`'s `Nominal`, as a class guard's edge binds
        # the subject, and marks it as that edge marks a local ({Narrowing.mark_gradual_local}). Only a capture of
        # the whole subject by a class or an alternation of classes is marked.
        def mark_gradual_class_capture(subject_type, pattern, scope, marked: false)
          return scope unless pattern.is_a?(Prism::CapturePatternNode) && class_capture_value?(pattern.value)

          name = pattern.target.name
          Narrowing.mark_gradual_local(scope, name, subject_type, scope.local(name), marked: marked)
        end

        def class_capture_value?(value)
          case value
          when Prism::ConstantReadNode, Prism::ConstantPathNode then true
          when Prism::AlternationPatternNode then class_capture_value?(value.left) && class_capture_value?(value.right)
          else false
          end
        end

        # Returns an array of `[Symbol, Rigor::Type]` pairs for every variable captured by `pattern`, typed against the
        # subject. Unrecognised pattern nodes contribute no bindings (fail-soft).
        #
        # A union subject distributes first (see {#collect_union_pattern_bindings}); every other subject walks the
        # pattern once, and each node kind decides how much of the subject it can name:
        #
        # - a bare target (`in [i, s]`, `in x`) binds the slot the enclosing pattern hands it,
        # - a capture (`Integer => i`, `[a, b] => whole`) binds its own constraint, and recurses into the captured
        #   pattern,
        # - an array / find / hash pattern decomposes the subject (see the three collectors below).
        def collect_in_pattern_bindings(subject_type, pattern, scope, evaluator, subject_node: nil)
          if subject_type.is_a?(Type::Union)
            return collect_union_pattern_bindings(subject_type.members, pattern, scope, evaluator,
                                                  subject_node: subject_node)
          end

          case pattern
          when Prism::CapturePatternNode
            collect_capture_pattern_bindings(subject_type, pattern, scope, evaluator)
          when Prism::LocalVariableTargetNode
            [[pattern.name, subject_type || Type::Combinator.untyped]]
          when Prism::ImplicitNode
            collect_in_pattern_bindings(subject_type, pattern.value, scope, evaluator)
          when Prism::ArrayPatternNode
            collect_array_pattern_bindings(subject_type, pattern, scope, evaluator, subject_node: subject_node)
          when Prism::FindPatternNode
            collect_find_pattern_bindings(subject_type, pattern, scope, evaluator, subject_node: subject_node)
          when Prism::HashPatternNode
            collect_hash_pattern_bindings(subject_type, pattern, scope, evaluator, subject_node: subject_node)
          when Prism::AlternationPatternNode
            collect_alternation_pattern_bindings(subject_type, pattern, scope, evaluator)
          else
            []
          end
        end

        # `pattern => target` binds `target` to what the pattern matched AND every name the pattern itself binds:
        # `in [a, b] => whole` binds `a`, `b` and `whole`. The target's own type is the pattern's constraint when it
        # names a class (`Integer => i`), and the subject otherwise — a capture over any other pattern IS the subject
        # the pattern matched.
        def collect_capture_pattern_bindings(subject_type, pattern, scope, evaluator)
          target = pattern.target
          inner = collect_in_pattern_bindings(subject_type, pattern.value, scope, evaluator)
          return inner unless target.is_a?(Prism::LocalVariableTargetNode)

          [[target.name, capture_pattern_type(subject_type, pattern.value, scope, evaluator)]] + inner
        end

        # `in [i, s]` / `in [a, *rest, z]` / `in Foo[a, b]`.
        def collect_array_pattern_bindings(subject_type, pattern, scope, evaluator, subject_node:)
          subject_type = pattern_class_constraint(subject_type, pattern.constant, scope, evaluator)
          fronts, rest_type, backs = pattern_slot_types(subject_type, pattern, scope, subject_node)
          bindings = pattern.requireds.each_with_index.flat_map do |elem, i|
            collect_in_pattern_bindings(fronts[i], elem, scope, evaluator)
          end
          bindings += pattern.posts.each_with_index.flat_map do |elem, i|
            collect_in_pattern_bindings(backs[i], elem, scope, evaluator)
          end
          append_array_splat_binding(bindings, pattern.rest, rest_type)
          bindings
        end

        # The per-slot types a positional pattern reads: the subject's own decomposition when it is a carrier
        # {MultiTargetBinder.decompose_slots} accepts (`Tuple`, `Array[T]`), else the `deconstruct` projection of a
        # subject that defines one (`Struct#deconstruct`, a `Data` instance, a class whose `deconstruct` names the
        # parts), else the `Dynamic[top]` floor per slot.
        def pattern_slot_types(subject_type, pattern, scope, subject_node)
          view = positional_pattern_view(subject_type, scope, subject_node)
          return floor_pattern_slots(pattern.requireds.size, pattern.posts.size, !pattern.rest.nil?) if view.nil?

          MultiTargetBinder.decompose_slots(
            view, front_count: pattern.requireds.size, back_count: pattern.posts.size,
                  rest_present: !pattern.rest.nil?, scope: scope
          )
        end

        # The carrier a positional pattern decomposes: the subject itself when {MultiTargetBinder} already accepts it,
        # else what the subject's `deconstruct` answers with (a `Tuple` / `Array[T]` carrier), else nil.
        #
        # `subject_node` rides along as the dispatch's call node so the `Struct` fold's freshness gate can see the
        # receiver: `case Point.new(1, 2); in [x, y]` is a freshly materialised instance and folds, while a stored
        # binding that may have been mutated since does not (ADR-48).
        def positional_pattern_view(subject_type, scope, subject_node)
          return subject_type if subject_type.is_a?(Type::Tuple)
          return subject_type if MultiTargetBinder.array_element_type(subject_type)

          deconstruct_projection(subject_type, scope, subject_node)
        end

        # What `subject.deconstruct` answers with, when that is a carrier this binder decomposes; nil otherwise —
        # an absent method, or `Struct#deconstruct`'s RBS `Array[untyped]` for a class whose members are not known.
        def deconstruct_projection(subject_type, scope, subject_node)
          result = struct_instance_projection(subject_type, :deconstruct, scope, subject_node) ||
                   pattern_decomposition_dispatch(subject_type, :deconstruct, [], scope) ||
                   source_decomposition_projection(subject_type, :deconstruct, [], scope)
          return nil if result.nil?
          return result if result.is_a?(Type::Tuple) || MultiTargetBinder.array_element_type(result)

          nil
        end

        # The inferred return type of a project-defined `deconstruct` / `deconstruct_keys` (issue #1122). The
        # dispatcher answers nil for a class no RBS describes: the body-inference tier that would type
        # `subject.deconstruct` lives on `ExpressionTyper` and needs the call NODE a pattern does not have, so
        # this asks the scope's own entry point for the same answer a resolved call site gets (ADR-84 memo
        # included). nil when the project defines no such method, or when the body's answer is the gradual floor.
        def source_decomposition_projection(subject_type, method_name, arg_types, scope)
          return nil unless subject_type.is_a?(Type::Nominal)

          def_node = own_definer_node(scope, subject_type.class_name, method_name)
          return nil if def_node.nil?

          result = scope.user_method_return(def_node, subject_type, arg_types)
          return nil if result.nil? || result.is_a?(Type::Dynamic) || result.is_a?(Type::Top)

          result
        end

        # The `def` node the receiver's OWN class defines `method_name` with, or nil. ADR-119 C2-e (#1615): asked of
        # `DefinerResolution`, so a slot rebuilt from an ADR-85 seed bundle is resolved to a node and the read files
        # its ADR-46 edge. UNKNOWN answers nil: an unsettled or forked chain, or a contested slot once ADR-119 C1d
        # fills the siblings. Conditional or reopened defs are not contested until C1d. A definer further up the
        # chain (a prepended or included module, a superclass) is not the own class's, so the owner check declines it.
        def own_definer_node(scope, class_name, method_name)
          case DefinerResolution.resolve(scope, class_name, method_name, :instance, question: :definer)
          in DefinerResolution::Known(answer: [node, owner])
            owner == class_name ? node : nil
          in DefinerResolution::UNKNOWN # the case/in contract needs one arm per answer
            nil
          in DefinerResolution::ABSENT # rubocop:disable Lint/DuplicateBranch -- see above
            nil
          end
        end

        # A `StructInstance`'s own projection — `Tuple` of its member values for `deconstruct`, `HashShape` of
        # its members for `deconstruct_keys` — or nil when the subject is another carrier or the projection would
        # be unsound.
        #
        # The `Struct` fold's freshness gate cannot answer for a pattern through the dispatcher: it asks whether
        # the CALL's receiver was freshly materialised (`Point.new(1, 2).x`), while a pattern's subject node IS
        # that materialisation (`case Point.new(1, 2); in [x, y]`). The gate still applies — a `Struct` is
        # mutable, so a stored binding's member map may be stale (ADR-48) — so this asks it the pattern's own
        # question, with the subject expression as the materialisation. A `Data` instance needs none of this:
        # it is frozen, and the dispatcher already projects it (see `DataFolding`).
        def struct_instance_projection(subject_type, method_name, scope, subject_node)
          return nil unless subject_type.is_a?(Type::StructInstance)
          return nil unless MethodDispatcher::StructMaterialization.materialization_call?(subject_node, scope)

          case method_name
          when :deconstruct then Type::Combinator.tuple_of(*subject_type.members.values)
          when :deconstruct_keys then Type::Combinator.hash_shape_of(subject_type.members.dup)
          end
        end

        # `deconstruct` / `deconstruct_keys` on a subject carrier. A `Dynamic` / `Top` answer is the gradual floor
        # rather than a method's result, so it reads as "cannot ask" to every caller here.
        #
        # The subject node is deliberately NOT passed as the dispatch's `call_node`: the tiers read a call node's
        # receiver and arguments, and a pattern's subject is any expression at all — `StructFolding`'s freshness
        # gate dereferences `call_node.receiver`, which a local read or a literal does not answer. The one
        # freshness question a pattern needs (`case Point.new(1, 2)`) is asked by
        # {#struct_instance_projection} instead.
        def pattern_decomposition_dispatch(subject_type, method_name, args, scope)
          return nil if subject_type.nil?

          result = MethodDispatcher.dispatch(
            receiver_type: subject_type, method_name: method_name, arg_types: args,
            environment: scope.environment, scope: scope
          )
          return nil if result.is_a?(Type::Dynamic) || result.is_a?(Type::Top)

          result
        end

        # `in [*pre, m, *post]`. Ruby matches a find pattern's required elements at the EARLIEST position the
        # surrounding splats allow (the pre-splat is non-greedy: `[1, 2, 3] in [*pre, x, *post]` binds `pre = []`, `x =
        # 1`), but a required that does not match there slides right, so each required binds the union of every
        # position it could occupy and the surrounding splats bind an `Array` of the subject's element type.
        def collect_find_pattern_bindings(subject_type, pattern, scope, evaluator, subject_node:)
          subject_type = pattern_class_constraint(subject_type, pattern.constant, scope, evaluator)
          view = positional_pattern_view(subject_type, scope, subject_node)
          slots = find_pattern_slots(view, pattern.requireds.size)
          bindings = pattern.requireds.each_with_index.flat_map do |elem, i|
            collect_in_pattern_bindings(slots ? slots[i] : Type::Combinator.untyped, elem, scope, evaluator)
          end
          surround = find_pattern_surround_type(view)
          [pattern.left, pattern.right].each { |splat| append_array_splat_binding(bindings, splat, surround) }
          bindings
        end

        # The type each of a find pattern's `count` requireds can see, or nil when the subject cannot supply that many
        # elements (the pattern cannot match).
        def find_pattern_slots(view, count)
          if view.is_a?(Type::Tuple)
            elements = view.elements
            return nil if elements.size < count

            return Array.new(count) { |i| Type::Combinator.union(*elements[i..(elements.size - count + i)]) }
          end

          element = view && MultiTargetBinder.array_element_type(view)
          element && Array.new(count) { element }
        end

        # `*pre` / `*post` capture the elements the requireds did not: `Array[T]` for an `Array[T]` subject, an `Array`
        # of the element union for a `Tuple`, `Array[untyped]` when the subject could not be decomposed.
        def find_pattern_surround_type(view)
          element = case view
                    when Type::Tuple then union_of_types(view.elements)
                    else view && MultiTargetBinder.array_element_type(view)
                    end
          Type::Combinator.nominal_of("Array", type_args: [element || Type::Combinator.untyped])
        end

        # `in {name: String => n}` / `in {name:, **rest}`. Each element reads the subject's value at its key through
        # the subject's `deconstruct_keys` projection; `**rest` binds the remaining entries.
        def collect_hash_pattern_bindings(subject_type, pattern, scope, evaluator, subject_node:)
          subject_type = pattern_class_constraint(subject_type, pattern.constant, scope, evaluator)
          view = hash_pattern_view(subject_type, scope, subject_node)
          bindings = pattern.elements.flat_map do |assoc|
            next [] unless assoc.is_a?(Prism::AssocNode) && assoc.value

            collect_in_pattern_bindings(hash_pattern_value_type(view, assoc.key), assoc.value, scope, evaluator)
          end
          rest = pattern.rest
          if rest.is_a?(Prism::AssocSplatNode) && rest.value.is_a?(Prism::LocalVariableTargetNode)
            bindings << [rest.value.name, hash_pattern_rest_type(view)]
          end
          bindings
        end

        # The `Hash`-shaped view a hash pattern reads: the subject's `deconstruct_keys` answer, which is a `HashShape`
        # for a shape carrier or a `deconstruct_keys` body and `Hash[K, V]` for the RBS answer of a plain `Hash` — or
        # nil when the subject cannot be asked.
        def hash_pattern_view(subject_type, scope, subject_node)
          args = [Type::Combinator.constant_of(nil)]
          struct_instance_projection(subject_type, :deconstruct_keys, scope, subject_node) ||
            pattern_decomposition_dispatch(subject_type, :deconstruct_keys, args, scope) ||
            source_decomposition_projection(subject_type, :deconstruct_keys, args, scope)
        end

        # The value type the pattern's key reads out of the view: a `HashShape` answers per key, a `Hash[K, V]`
        # answers `V` for every key, and anything else — a key the AST does not pin (`in {"#{k}": v}`), a shape that
        # does not carry the key — answers the floor.
        def hash_pattern_value_type(view, key_node)
          key = hash_pattern_key(key_node)
          return Type::Combinator.untyped if key.nil?
          return view.pairs[key] || Type::Combinator.untyped if view.is_a?(Type::HashShape)

          hash_value_type(view) || Type::Combinator.untyped
        end

        # The key a hash pattern element names, or nil when the AST does not pin one (an interpolated or computed key).
        def hash_pattern_key(key_node)
          case key_node
          when Prism::SymbolNode then key_node.unescaped.to_sym
          when Prism::StringNode then key_node.unescaped
          end
        end

        # `{ key:, **rest }` binds `rest` to a Hash whose keys are Symbols (the only legal key shape for a hash pattern)
        # and whose values are the view's own value type — the entries the pattern named are a subset of it.
        def hash_pattern_rest_type(view)
          value = view.is_a?(Type::HashShape) ? union_of_types(view.pairs.values) : hash_value_type(view)
          Type::Combinator.nominal_of(
            "Hash",
            type_args: [Type::Combinator.nominal_of("Symbol"), value || Type::Combinator.untyped]
          )
        end

        # The `V` of a `Hash[K, V]`, or nil for a raw `Hash`, a non-`Hash` nominal, or a `Dynamic` / `Top` value.
        def hash_value_type(type)
          return nil unless type.is_a?(Type::Nominal) && type.class_name == "Hash" && type.type_args.size == 2

          value = type.type_args.last
          return nil if value.is_a?(Type::Dynamic) || value.is_a?(Type::Top)

          value
        end

        # The union of a list of types, ignoring the gradual floor (`Dynamic[top]` / `Top` carries nothing to union)
        # and answering nil when nothing is left.
        def union_of_types(types)
          known = types.reject { |type| type.is_a?(Type::Dynamic) || type.is_a?(Type::Top) }
          known.empty? ? nil : Type::Combinator.union(*known)
        end

        # `[..., *rest, ...]` / `[*pre, x, *post]` capture an Array of the unmatched elements. `rest_type` is the
        # enclosing decomposition's own rest (a `Tuple` of the middle elements for a tuple subject, `Array[T]` for an
        # `Array[T]`); without one — a subject that did not decompose — the rest is `Array[untyped]`.
        def append_array_splat_binding(bindings, splat, rest_type)
          return unless splat.is_a?(Prism::SplatNode)

          target = splat.expression
          return unless target.is_a?(Prism::LocalVariableTargetNode)

          bindings << [target.name, rest_type || Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped])]
        end

        # The `Dynamic[top]` floor per slot, for a subject no rule decomposes.
        def floor_pattern_slots(front_count, back_count, rest_present)
          [
            Array.new(front_count) { Type::Combinator.untyped },
            rest_present ? Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped]) : nil,
            Array.new(back_count) { Type::Combinator.untyped }
          ]
        end

        # The class a pattern's own constant asserts (`in Point[x, y]`, `in Foo{...}`), applied to the subject. An
        # opaque subject — `Dynamic` / `Top`, which no `is_a?`-style narrowing can refine — becomes `Nominal[C]`: the
        # pattern's `C === subject` test has just established the class, which is what lets a constrained pattern bind
        # off a subject whose own type named nothing. A subject whose class is already known keeps it.
        def pattern_class_constraint(subject_type, constant_node, scope, evaluator)
          return subject_type if constant_node.nil?

          nominal = singleton_to_nominal(evaluator.sub_eval(constant_node, scope).first)
          return subject_type unless opaque_pattern_subject?(subject_type)
          return subject_type if nominal.is_a?(Type::Dynamic) || nominal.is_a?(Type::Top)

          nominal
        end

        def opaque_pattern_subject?(subject_type)
          subject_type.nil? || subject_type.is_a?(Type::Dynamic) || subject_type.is_a?(Type::Top)
        end

        # Distributes a union subject over the pattern, the rule {MultiTargetBinder} applies to `a, b = union`: every
        # member walks the same pattern and each name binds the join of its per-member types, while a member that binds
        # `Dynamic[top]` floors the name for the whole union — a precise member must not stand for one nothing is known
        # about. A member that PROVABLY cannot match the pattern contributes nothing at all instead of flooring:
        # `case maybe; in [a, b]` over `Tuple[1, "a"] | nil` binds `1` / `"a"`, because a `nil` subject raises
        # `NoMatchingPatternError` rather than reaching the body.
        def collect_union_pattern_bindings(members, pattern, scope, evaluator, subject_node: nil)
          reachable = members.reject { |member| pattern_match_impossible?(member, pattern, scope) }
          walks = (reachable.empty? ? [Type::Combinator.untyped] : reachable).map do |member|
            collect_in_pattern_bindings(member, pattern, scope, evaluator, subject_node: subject_node)
          end
          merge_pattern_bindings(walks)
        end

        # Whether `type` provably cannot match `pattern`, so its arm contributes no binding. Only the two
        # decompositions a pattern asks for are checked — `deconstruct` (array / find patterns) and `deconstruct_keys`
        # (hash patterns) — and both only for a class the RBS environment knows, whose method set is closed, the same
        # rule `array_conversion_free?` applies to the multi-assign `to_ary` question (issue #1094). A carrier the
        # check cannot prove negative about (Dynamic, a source class, an unresolved constant) answers false, which
        # keeps the union at the conservative floor.
        def pattern_match_impossible?(type, pattern, scope)
          case pattern
          when Prism::ArrayPatternNode, Prism::FindPatternNode then !decomposable_as_array?(type, scope)
          when Prism::HashPatternNode then !decomposable_as_hash?(type, scope)
          when Prism::CapturePatternNode then pattern_match_impossible?(type, pattern.value, scope)
          else false
          end
        end

        def decomposable_as_array?(type, scope)
          return true unless pattern_decomposition_dispatch(type, :deconstruct, [], scope).nil?

          class_name = MultiTargetBinder.conversion_class_name(type)
          class_name.nil? || !MethodDispatcher::RbsDispatch.array_conversion_free?(class_name, scope)
        end

        def decomposable_as_hash?(type, scope)
          args = [Type::Combinator.constant_of(nil)]
          return true unless pattern_decomposition_dispatch(type, :deconstruct_keys, args, scope).nil?

          class_name = MultiTargetBinder.conversion_class_name(type)
          return true if class_name.nil? || scope.environment.nil?

          !Reflection.rbs_class_known?(class_name, environment: scope.environment)
        end

        # Joins per-member binding lists by name: `Dynamic[top]` from any walk — or a name a walk does not bind —
        # floors the name, otherwise the members union. The first walk's order is the declaration order.
        def merge_pattern_bindings(walks)
          floor = Type::Combinator.untyped
          walks.first.map do |name, _type|
            types = walks.map { |walk| walk.assoc(name)&.last }
            floored = types.any? { |type| type.nil? || Type::Combinator.untyped?(type) }
            [name, floored ? floor : Type::Combinator.union(*types)]
          end
        end

        # `expr in pattern` (a `MatchPredicateNode`, evaluating to a boolean) and `expr => pattern` (a
        # `MatchRequiredNode`, evaluating to `nil` and raising `NoMatchingPatternError` on a mismatch) — the one-line
        # pattern matches. Both bind every name the pattern captures into the post-scope, decomposed exactly as an `in`
        # branch of a `case` is, and WITHOUT the nil-injection a surrounding join would add: a name is read on the
        # truthy side only after the pattern matched it, which is the shape `if config in {timeout: Integer => t}`
        # depends on.
        def eval_match_pattern(node, scope, tracer, evaluator)
          subject_type, post_value = evaluator.sub_eval(node.value, scope)
          bound = apply_in_pattern_bindings(subject_type, node.value, node.pattern, post_value, evaluator)
          [scope.type_of(node, tracer: tracer), bound]
        end

        # --------------------------------------------------------------- named-capture regex binding (`MatchWriteNode`)
        # ---------------------------------------------------------------

        # `/(?<year>\d+)/ =~ str` — Prism emits a `MatchWriteNode` that wraps the `=~` call and lists the named-capture
        # targets. Each target is bound to `String | nil` (the capture is absent as nil when the pattern doesn't match
        # or the group didn't participate).
        def eval_match_write(node, scope, evaluator)
          match_type, post_scope = evaluator.sub_eval(node.call, scope)
          string_or_nil = Type::Combinator.union(
            Type::Combinator.nominal_of("String"),
            Type::Combinator.constant_of(nil)
          )
          bound_scope = node.targets.reduce(post_scope) do |s, target|
            next s unless target.is_a?(Prism::LocalVariableTargetNode)

            s.with_local(target.name, string_or_nil)
          end
          [match_type, bound_scope]
        end

        # --------------------------------------------------------------- shared type conversion helper
        # ---------------------------------------------------------------

        # Converts a `Singleton[ClassName]` (the class object) to the corresponding `Nominal[ClassName]` (an instance).
        # Falls back to `untyped` for carriers that are not Singleton (e.g. Dynamic[Top] when the class could not be
        # resolved).
        def singleton_to_nominal(type)
          type.is_a?(Type::Singleton) ? Type::Combinator.nominal_of(type.class_name) : Type::Combinator.untyped
        end

        # Returns the type to bind for a `CapturePatternNode`'s target. A class reference (`Integer => x`, and every
        # alternate of `Integer | String => x`) answers the constraint's `Nominal[T]` — the pattern's own `T ===
        # subject` test is what licenses the binding even when the subject's type is opaque. A value pattern (`1 => x`)
        # answers the literal's own type. A capture over any other pattern (`[a, b] => whole`, `^(x) => y`) answers the
        # subject, which is what that pattern matched.
        def capture_pattern_type(subject_type, value_node, scope, evaluator)
          case value_node
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            singleton_to_nominal(evaluator.sub_eval(value_node, scope).first)
          when Prism::AlternationPatternNode
            Type::Combinator.union(
              capture_pattern_type(subject_type, value_node.left, scope, evaluator),
              capture_pattern_type(subject_type, value_node.right, scope, evaluator)
            )
          when Prism::ArrayPatternNode, Prism::FindPatternNode, Prism::HashPatternNode,
               Prism::PinnedVariableNode, Prism::PinnedExpressionNode, Prism::ImplicitNode
            subject_type || Type::Combinator.untyped
          else
            literal_pattern_type(value_node, scope, evaluator)
          end
        end

        # The type a non-class pattern node evaluates to: `Constant[1]` for `1 => x`, the nominal for `/re/ => x`,
        # the range for `1..5 => x`. A class reference is the one carrier that must convert (`Singleton[C]` is the
        # class object; the binding holds an instance), which the caller's constant arm does.
        def literal_pattern_type(value_node, scope, evaluator)
          type = evaluator.sub_eval(value_node, scope).first
          type.is_a?(Type::Singleton) ? singleton_to_nominal(type) : type
        end

        # `in PatternA | PatternB` — Ruby rejects a named capture inside an alternative pattern (only `_`-prefixed names
        # compile), so the binder, which runs against the AST, simply collects bindings from each side and merges by
        # name, unioning types when both alternates contribute. A name only one alternate contributes still surfaces.
        def collect_alternation_pattern_bindings(subject_type, pattern, scope, evaluator)
          left = collect_in_pattern_bindings(subject_type, pattern.left, scope, evaluator)
          right = collect_in_pattern_bindings(subject_type, pattern.right, scope, evaluator)
          merged = {}
          (left + right).each do |name, type|
            merged[name] = merged.key?(name) ? Type::Combinator.union(merged[name], type) : type
          end
          merged.to_a
        end

        private_class_method :rescue_exception_type, :mark_gradual_class_capture, :class_capture_value?,
                             :collect_in_pattern_bindings, :collect_capture_pattern_bindings,
                             :collect_array_pattern_bindings, :pattern_slot_types, :positional_pattern_view,
                             :deconstruct_projection, :source_decomposition_projection, :own_definer_node,
                             :struct_instance_projection, :pattern_decomposition_dispatch,
                             :collect_find_pattern_bindings, :find_pattern_slots, :find_pattern_surround_type,
                             :collect_hash_pattern_bindings, :hash_pattern_view, :hash_pattern_value_type,
                             :hash_pattern_key, :hash_pattern_rest_type, :hash_value_type, :union_of_types,
                             :append_array_splat_binding, :floor_pattern_slots, :pattern_class_constraint,
                             :opaque_pattern_subject?, :collect_union_pattern_bindings, :pattern_match_impossible?,
                             :decomposable_as_array?, :decomposable_as_hash?, :merge_pattern_bindings,
                             :singleton_to_nominal, :capture_pattern_type, :literal_pattern_type,
                             :collect_alternation_pattern_bindings
      end
    end
  end
end
