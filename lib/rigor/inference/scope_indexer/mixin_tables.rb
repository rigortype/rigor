# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../declaration_walk/rules"
require_relative "../object_mixins"
require_relative "constant_tables"
require_relative "mixin_accumulator"
require_relative "mixin_effects"

module Rigor
  module Inference
    module ScopeIndexer
      # The mixin tables of one file, moved out of `scope_indexer.rb` whole (ADR-116 WD9, #3400): per class or
      # module, the modules it `include`s and the ones it `prepend`s, as written, in instance-ancestor search order
      # (ADR-24 slice 2, #1123, #1173), and the edges whose order is not a fact ({MixinAccumulator}).
      # {.mixin_tables} is the entry: one descent answers the three tables, and the per-file merge
      # (`ScopeIndexer.merge_mixin_tables`) and the cross-file fold (`ScopeIndexer.fold_file_mixin_tables`) call
      # it. The other 16 functions are private: the walk with its arms, the two recording steps, the projection of
      # the accumulator, the owner of a top-level `include` (#1697), and {.build_discovered_includes} and
      # {.build_discovered_prepends}, each one table of the three, which no file of `lib/` calls and the specs reach
      # through `send`.
      #
      # It asks {DeclarationWalk::Rules} for each declaration context, {ConstantTables} for the `self` a block runs
      # under, and {MixinEffects} for what a mixin call reshapes and taints, which the extend walk asks too. It calls
      # two functions left in `scope_indexer.rb`, recognisers the other walkers ask too, at two sites each:
      # `ScopeIndexer.mixin_call_view` and `ScopeIndexer.lexical_self_receiver?`. No constant moved with it. It reads
      # `ScopeIndexer::OPAQUE_SELF`, `INSTANCE_MIXIN_NAMES` and `MIXIN_CALL_NAMES` lexically, as {NodePropagation}
      # reads the indexer's constants: other rows of `scope_indexer.rb` and other modules read each.
      #
      # `scope_indexer.rb` requires this file, and this file does not require it back. It requires the file of what
      # else it names. So the file loads alone, and until `scope_indexer.rb` has loaded the entry answers only for a
      # program with no call but the factory call of a constant write that creates a class: any other call is a
      # `NoMethodError` (`mixin_call_view`).
      module MixinTables
        module_function

        # ADR-24 slice 2 — per-class/module table mapping a fully qualified user class or module to the list of module
        # names it `include`s / `prepend`s, AS WRITTEN at the mixin call (`include Foo` / `include Foo::Bar`). Only
        # constant arguments are recorded; dynamic mixins (`include some_method`) produce no entry. The names are
        # spelled as written but ordered in instance-ancestor SEARCH order since #1173: prepended modules first
        # (Ruby puts them ahead of the class itself), then includes nearest-first (`include A; include B` searches
        # B first; `include A, B` keeps `["A", "B"]`). `prepend` is ALSO recorded in its own
        # {.build_discovered_prepends} table, which is what tells the two apart at `def`-priority level. `extend` is NOT
        # tracked (it adds singleton methods; ADR-24 slice 2 resolves the instance-side chain).
        def build_discovered_includes(root)
          mixin_tables(root).fetch(:includes)
        end

        # Issue #1123 — `{qualified class or module name => [module names it `prepend`s, as written]}`,
        # stored in instance-ancestor SEARCH order: a later `prepend` statement puts its module NEARER than
        # an earlier one (`prepend A; prepend B` searches B before A) while the arguments of ONE
        # `prepend A, B` keep call order — exactly the convention {ScopeIndexer.record_extend_targets} documents for
        # `extend`, and the order `Scope::ResolutionChain` reads a body's prepends in. Ruby inserts a
        # prepended module, and its own ancestry, immediately BEFORE the class that prepends it, so these
        # names outrank the class's own `def`s; without the kind recorded separately from {.build_discovered_includes}
        # there was nothing to order on and `prepend` was silently an `include`.
        def build_discovered_prepends(root)
          mixin_tables(root).fetch(:prepends)
        end

        # One descent, both instance-side mixin tables: the walk classifies each mixin call it sees, so the
        # two tables cost one walk rather than two. Each value is frozen and de-duplicated per class, as the
        # single-table builder always did. `:unpositioned` names the recorded edges whose order is not a fact
        # ({MixinAccumulator}).
        def mixin_tables(root)
          accumulator = MixinAccumulator.new
          accumulator.direct_body(MixinEffects.program_statements(root))
          accumulator.program_body(MixinEffects.program_statements(root))
          walk_class_includes(root, [], nil, accumulator)
          {
            includes: freeze_mixin_lists(accumulator, :include),
            prepends: freeze_mixin_lists(accumulator, :prepend),
            unpositioned: accumulator.unpositioned
          }
        end

        # The `{include: [...], prepend: [...]}`-valued accumulator {.mixin_tables} fills is keyed by class
        # first and kind second, because one walk feeds both tables; this projects one kind out of it. A class
        # with no names of that kind is DROPPED rather than stored as an empty list, which is the shape the
        # single-table builder always had (consumers take the absence of an entry as "mixes nothing in").
        #
        # Issue #1173 — the `:include` projection prepends the `:prepend` names: a prepended module sits
        # ahead of the class ITSELF in the runtime ancestry, and therefore ahead of every include, so the
        # instance-ancestor search order this table now keeps is `prepends ++ includes`. Both buckets
        # already store nearest-first (see {.write_mixin_targets}), so the concat preserves MRO.
        def freeze_mixin_lists(accumulator, kind)
          accumulator.each_with_object({}) do |(class_name, kinds), out|
            names = mixin_names_for(kinds, kind)
            # The instance-side projection is a SET in search order; the prepend table keeps every statement.
            names = names.uniq if kind == :include
            names = names.freeze
            out[class_name] = names unless names.empty?
          end.freeze
        end

        # One bucket's frozen list: `:include` is every instance-side mixin in search order (prepends
        # first), `:prepend` the wedge table alone.
        def mixin_names_for(kinds, kind)
          if kind == :include
            (kinds[:prepend] || []) + (kinds[:include] || [])
          else
            kinds[kind] || []
          end
        end

        def walk_class_includes(node, qualified_prefix, current_class, accumulator,
                                singleton_self: false, singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return if walk_includes_declaration?(node, qualified_prefix, current_class, accumulator,
                                                 singleton_cref)
          when Prism::SingletonClassNode
            # Issue #728 — `class << self; include M; end` mixes M into the SINGLETON: it contributes class
            # methods, not the instance surface this table feeds. Descending with no owner keeps any nested
            # declaration walked (a `ClassNode` child sets its own owner) while the mixin calls in the
            # singleton body record nothing, which is what `extends` is for — and since #915 the extend walk
            # does take them, so the form is recorded rather than dropped. `self` inside is
            # the singleton — a `self::` receiver below raises NameError at runtime, so it
            # declines rather than resolving against the enclosing class. The `class <<`
            # EXPRESSION itself evaluates in the enclosing context, so it walks without
            # either marker.
            return walk_singleton_class_includes(node, qualified_prefix, current_class, accumulator,
                                                 singleton_self, singleton_cref)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathOrWriteNode
            return if walk_includes_meta_new?(node, qualified_prefix, current_class, accumulator,
                                              singleton_self, singleton_cref)
          when Prism::CallNode
            record_mixin_call(node, qualified_prefix, current_class, accumulator)
            return walk_mixin_call_children(node, qualified_prefix, current_class, accumulator,
                                            singleton_self, singleton_cref)
          end

          walk_includes_children(node, qualified_prefix, current_class, accumulator, singleton_self, singleton_cref)
        end

        # The generic descent of {.walk_class_includes}; a `self.included(base)`-style hook's body walks with
        # its parameters in scope ({MixinAccumulator#with_hook_params}).
        def walk_includes_children(node, qualified_prefix, current_class, accumulator, singleton_self, singleton_cref)
          hook_params = MixinEffects.hook_def_params(node)
          if hook_params
            return accumulator.with_hook_params(hook_params) do
              walk_includes_children_plain(node, qualified_prefix, current_class, accumulator, singleton_self,
                                           singleton_cref)
            end
          end

          walk_includes_children_plain(node, qualified_prefix, current_class, accumulator, singleton_self,
                                       singleton_cref)
        end

        def walk_includes_children_plain(node, qualified_prefix, current_class, accumulator, singleton_self,
                                         singleton_cref)
          node.rigor_each_child do |child|
            walk_class_includes(child, qualified_prefix, current_class, accumulator,
                                singleton_self: singleton_self, singleton_cref: singleton_cref)
          end
        end

        # The class/module arm of {.walk_class_includes}: under an unnameable cref a
        # bare/`self::` header opens `#<singleton>::Name` — ownerless; nameable headers
        # re-anchor at a real cref.
        def walk_includes_declaration?(node, qualified_prefix, current_class, accumulator,
                                       singleton_cref)
          ctx = DeclarationWalk::Rules.decl_body_context(node, qualified_prefix, current_class && [current_class],
                                                         singleton_cref)
          return false unless ctx
          return true unless node.body

          _self_decl, child_prefix, child_cref = ctx
          accumulator.direct_body(node.body) if accumulator.direct?(node)
          accumulator.class_body(node.body)
          walk_class_includes(node.body, child_cref ? [] : child_prefix,
                              child_cref ? nil : child_prefix.join("::"), accumulator,
                              singleton_cref: child_cref)
          true
        end

        # The `class <<` arm of {.walk_class_includes}: the expression evaluates in the enclosing
        # context while the body is the singleton's — ownerless here (`extends` owns its mixins),
        # with `self` unnameable and an unnameable cref.
        def walk_singleton_class_includes(node, qualified_prefix, current_class, accumulator,
                                          singleton_self, singleton_cref)
          walk_class_includes(node.expression, qualified_prefix, current_class, accumulator,
                              singleton_self: singleton_self, singleton_cref: singleton_cref)
          return unless node.body

          walk_class_includes(node.body, qualified_prefix, nil, accumulator,
                              singleton_self: true, singleton_cref: true)
        end

        # `K = Class.new { include T }` mixes T into the block's class — the nameable `K`, or
        # ownerless when the write lands on an unnameable cref. Returns whether a meta-new block
        # body was found (the write's other children are left to the caller).
        def walk_includes_meta_new?(node, qualified_prefix, current_class, accumulator, singleton_self,
                                    singleton_cref)
          call = DeclarationWalk::Rules.meta_new_block_call(node)
          return false unless call

          meta_owner = MixinEffects.meta_new_mixin_owner(node, qualified_prefix, singleton_cref,
                                                         current_class && [current_class])
          # The block rebinds only `self` — `Module.nesting` stays lexical — so the cref
          # flag passes through unchanged: a nested `class Inner` under `class <<` still
          # lands on the singleton's table, while mixin leaves attribute to `meta_owner`.
          body_cref = singleton_cref
          # The factory call's receiver and arguments evaluate in the ENCLOSING context —
          # `K = Class.new(X.class_eval { include T })` still mixes T into X — while the
          # block is the class body of the class the write names.
          if call.receiver
            walk_class_includes(call.receiver, qualified_prefix, current_class, accumulator,
                                singleton_self: singleton_self, singleton_cref: singleton_cref)
          end
          call.arguments&.arguments&.each do |arg|
            walk_class_includes(arg, qualified_prefix, current_class, accumulator,
                                singleton_self: singleton_self, singleton_cref: singleton_cref)
          end
          if (body = DeclarationWalk::Rules.meta_new_block_body(node))
            walk_class_includes(body, qualified_prefix, meta_owner, accumulator,
                                singleton_cref: body_cref)
          end
          true
        end

        # Issue #728 — a block that REBINDS `self` owns the mixin calls written in it, not the lexically enclosing
        # declaration: `Thing = Class.new { include Taggable }` inside `class Outer` must not register `Taggable` on
        # `Outer`, where `Outer.new.tag` raises `NoMethodError` in MRI. The classification is
        # {ConstantTables.rebound_block_self}, the same one #721 gave its own mixin scan.
        #
        # `Recv.class_eval { include M }` resolves to `Recv` and records there. An OPAQUE rebinding — `Class.new` /
        # `Module.new` / a non-constant `class_eval` receiver — records nothing: the class exists but this walk cannot
        # name it, and naming the lexical enclosure instead is the one answer Ruby is guaranteed not to have written.
        def walk_mixin_call_children(node, qualified_prefix, current_class, accumulator, singleton_self,
                                     singleton_cref)
          # `self` is unnameable whenever the singleton marker is set OR the body is ownerless
          # under an unnameable cref (`class D` inside `class <<`, a declined eval body) — a
          # `self::` receiver inside either raises NameError or resolves on a table nothing
          # names, so it declines rather than re-anchoring to the lexical class.
          unnameable_self = singleton_self || (singleton_cref && current_class.nil?)
          rebound = ConstantTables.rebound_block_self(node, qualified_prefix, nil, nil,
                                                      unnameable_self ? OPAQUE_SELF : current_class)
          node.rigor_each_child do |child|
            rebinds_self = rebound && child.is_a?(Prism::BlockNode)
            owner =
              if rebinds_self
                rebound == OPAQUE_SELF ? nil : rebound
              else
                current_class
              end
            # A rebound block's own self is the receiver again — nameable only when the rebound
            # is; an OPAQUE rebound keeps the self unnameable — but `Module.nesting` never
            # rebinds, so the unnameable-cref marker crosses the block unchanged.
            child_unnameable = rebinds_self ? rebound == OPAQUE_SELF : unnameable_self
            walk_class_includes(child, qualified_prefix, owner, accumulator,
                                singleton_self: child_unnameable, singleton_cref: singleton_cref)
          end
        end

        # A receiverless `include Foo` / `prepend Foo` written in a declaration body contributes both tables;
        # the receiver form (`Base.prepend(Loud)`, issue #1123) does too — a call form puts the module in the
        # class's instance ancestry exactly as the declaration form does, so `discovered_includes` must carry
        # it or the set-shaped consumers (arity, visibility, undefined-method suppression) would answer
        # differently for the two spellings of one edge.
        def record_mixin_call(node, qualified_prefix, current_class, accumulator)
          MixinEffects.taint_opaque_eval(node, current_class, accumulator)
          view = ScopeIndexer.mixin_call_view(node)
          if view.nil?
            return MixinEffects.taint_computed_mixin_send(node, current_class, accumulator, INSTANCE_MIXIN_NAMES,
                                                          :include)
          end
          return if view.first.nil?

          kind = view.first
          current_class ||= toplevel_include_owner(node, qualified_prefix, current_class, accumulator)
          effects = MixinEffects.mixin_effects(node, kind, qualified_prefix, current_class, accumulator,
                                               in_singleton: false)
                                .select { |_owner, side| side == :include }
          return if effects.empty?
          return if instance_mixin_recorded?(node, view, qualified_prefix, current_class, accumulator)

          # A mixin call the tables cannot hold still reshapes the ancestry: taint the whole owner side.
          MixinEffects.taint_unrecorded_mixin(node, kind, view[1], effects, accumulator)
        end

        # Records the instance-side edges of an `include` / `prepend` call. False when it recorded nothing — the caller
        # then taints the owner instead. `view` is {ScopeIndexer.mixin_call_view}'s, so `Integer.send(:include, Ext)`
        # records `Ext` as `Integer.include(Ext)` does (issue #1722).
        #
        # A receiverless `include` / `prepend` needs an enclosing declaration to file the edge under, and the RECEIVER
        # form (`Base.prepend(Loud)`, issue #1123; `Integer.include(Ext)` and `Integer.send(:include, Ext)`, issue
        # #1722) files it under the class the receiver names. A receiver-form edge is unpositioned wherever it is
        # written ({MixinAccumulator#note}), so a reader that depends on ORDER declines on it, while the set-shaped
        # readers (undefined-method suppression, arity, visibility) see the module as they see an in-body `include`.
        #
        # Issue #2995 — `self.include M`, `self.prepend M` and a receiverless or `self.` `send` / `public_send` /
        # `__send__(:include | :prepend, M)` are the same call on the same `self` as a bare `include M`, so they file
        # the edge under the enclosing class as it does, positioned where it would be ({MixinAccumulator#note}). The
        # walk names that `self` exactly where it names a bare `include`'s: `current_class` is nil wherever it cannot.
        def instance_mixin_recorded?(node, view, qualified_prefix, current_class, accumulator)
          kind, arguments, = view
          return false unless mixin_call_recorded?(kind)

          targets = arguments.filter_map { |arg| Source::ConstantPath.qualified_name(arg) }
          return false if targets.empty?

          owner =
            if ScopeIndexer.lexical_self_receiver?(node.receiver)
              current_class
            else
              MixinEffects.prepend_call_receiver(node, qualified_prefix)
            end
          return false if owner.nil?

          write_mixin_targets(accumulator, owner, targets, prepend: kind == :prepend)
          accumulator.note(node, owner, :include, targets, complete: targets.size == arguments.size)
          true
        end

        # Issue #1123 — one class's contribution to the two tables. A prepended module lands in BOTH: the
        # include list is the SET of modules a class carries (arity, visibility, reflection and constant-scope
        # consumers read it that way), while the prepend table adds the ORDER and the KIND.
        #
        # Issue #1173 — `include` now stores instance-ancestor SEARCH order too, the same convention
        # `prepend` already keeps: each statement's argument list lands as one unit (`include A, B` keeps
        # `["A", "B"]`, the order Ruby searches them) AHEAD of the earlier statements' (`include A;
        # include B` searches B first). Call order was never a semantic — it is where this list happened
        # to be written — and every order-sensitive consumer (the BFS mixin step, the external-ancestor
        # walk, override visibility) reads nearer-first. A re-`include` of an already-carried name is a
        # runtime no-op (`Module#append_features` is skipped when the module is already an ancestor), so
        # a present target does not re-position itself. The prepend names still join the include list at
        # freeze time — ahead of every include, where Ruby puts them.
        def write_mixin_targets(accumulator, owner, targets, prepend:)
          bucket = accumulator[owner] ||= {}
          kind, other = prepend ? %i[prepend include] : %i[include prepend]
          list = (bucket[kind] ||= [])
          # A target the OTHER kind already carries (`include M; prepend M`) is one body the two tables cannot
          # represent (Ruby's `[M, C, M]`), so the instance side is named unpositioned.
          accumulator.taint(owner, :include) if targets.any? { |target| bucket[other]&.include?(target) }
          # A repeated `include` keeps its first position (Ruby skips it). A repeated `prepend` is KEPT: the
          # prepend table holds every statement, nearest first, so the readers that walk the raw list see what
          # they always saw, and the resolution chain dedupes per owner, first statement winning.
          list.unshift(*(prepend ? targets : targets.reject { |target| list.include?(target) }))
        end

        # Whether a mixin call's kind reaches the instance-side tables: `include` and `prepend`.
        def mixin_call_recorded?(kind) = MIXIN_CALL_NAMES.include?(kind)

        # Issue #1697 — a receiverless `include M` written as a statement of the file's own top level is
        # `main.include`, which is `Object.include`: it mixes M into `Object`. It is recorded under its own
        # owner key, `ObjectMixins::TOPLEVEL_INCLUDE_KEY`, rather than on `Object`, so it rides every table an include
        # rides (the declaration signature, `discovered_class_sources`, the seed bundle) while no ancestry
        # walk that types a call reaches it: what Ruby reaches first for a name such an include supplies
        # depends on more than the chain shows (a block that rebinds `self`, an `extend` or a singleton `def`
        # on `main`), so only the diagnostic silences read it (`Inference::ObjectMixins`), and typing is
        # issue #1715's. `main` has no `prepend`, and a top-level `extend M` reaches `main`'s singleton alone, so
        # neither is recorded.
        #
        # Issue #3007 — the call counts wherever {MixinAccumulator::MainSelfCalls} takes its `self` to be `main`: a
        # program statement, or a call under top-level control flow (`if`, `begin`, `case`, …) or in a top-level
        # `def` body. Such a call may not run, so its edge is in the set with no position ({MixinAccumulator#note}),
        # as ADR-119 WD7 records an `include` in a method body. The same call inside a top-level block stays
        # unrecorded: its `self` may not be `main` (a `describe do include M end` or `class_exec` block rebinds it,
        # while `[1].each do include M end` does not, and the walk cannot tell them apart).
        #
        # Issue #2995 — `self.include M`, a receiverless or `self.` `send(:include, M)` and its `__send__` twin are the
        # same `main.include`. `public_send(:include, M)` is not: `main`'s `include` is private, so it raises.
        def toplevel_include_owner(node, qualified_prefix, current_class, accumulator)
          return nil unless current_class.nil? && qualified_prefix.empty?
          return nil unless ScopeIndexer.lexical_self_receiver?(node.receiver) && node.name != :public_send
          return nil unless ScopeIndexer.mixin_call_view(node)&.first == :include

          accumulator.program_statement?(node) ? ObjectMixins::TOPLEVEL_INCLUDE_KEY : nil
        end

        private_class_method :build_discovered_includes, :build_discovered_prepends, :freeze_mixin_lists,
                             :mixin_names_for, :walk_class_includes, :walk_includes_children,
                             :walk_includes_children_plain, :walk_includes_declaration?,
                             :walk_singleton_class_includes, :walk_includes_meta_new?, :walk_mixin_call_children,
                             :record_mixin_call, :instance_mixin_recorded?, :write_mixin_targets,
                             :mixin_call_recorded?, :toplevel_include_owner
      end
    end
  end
end
