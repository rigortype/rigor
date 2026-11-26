# frozen_string_literal: true

require "prism"

require_relative "../../type"
require_relative "../../source/node_children"
require_relative "../declaration_walk/traversal"
require_relative "../declaration_walk/rules"
require_relative "census_scope"
require_relative "class_cvars_collector"
require_relative "empty_seed"

module Rigor
  module Inference
    module ScopeIndexer
      # The class-variable census of one file (slice 7 phase 6), moved out of `scope_indexer.rb` whole (ADR-116
      # WD9, U5). {.build_class_cvar_index} is the entry `ScopeIndexer.index` calls: the `class_cvars` discovery
      # table, built by {ClassCvarsCollector} on the shared {DeclarationWalk}. The collector, a sibling file, calls
      # the other three public functions: {.collect_def_cvar_writes} and {.collect_body_cvar_writes} gather a
      # body's writes into its table, and {.finished_cvar_census} closes it. The rest is private: the gather and
      # its recording steps, and the walker the collector replaced ({.legacy_class_cvar_index} and its arms), kept
      # as the oracle `RIGOR_SHADOW_RULE_WALK` checks the collector against. {JoinOnlyCvarWrite} is the mark a
      # joining write carries until the census is finished; {CvarHierarchy}, a sibling file, reads it too.
      #
      # It asks {DeclarationWalk::Rules} for each declaration context and {CensusScope}, at two sites, for the scope
      # a census types a body's rvalues under, which the ivar and the constant censuses also ask. It calls nothing
      # left in `scope_indexer.rb`. `scope_indexer.rb` requires this file, and this file does not require it back.
      # It reads `ScopeIndexer::EMPTY_NESTING` lexically, as {NodePropagation} reads the indexer's constants, and
      # two constants of the ivar census by a path, {ClassIvarIndex::IVAR_BARRIER_NODES} and
      # {ClassIvarIndex::BindingTargets}. It does not require that module's file, which requires the dispatcher and
      # so the `rbs` gem, where this one loads without either. So the file loads alone, and until
      # `scope_indexer.rb` has loaded only {.finished_cvar_census} answers every call: the entry is a `NameError`,
      # and a gather answers for a body it skips and is a `NameError` for one it would type.
      module ClassCvarCensus
        module_function

        # Slice 7 phase 6 — class-cvar pre-pass. Same shape as the ivar pre-pass but collects
        # `Prism::ClassVariableWriteNode` writes inside ANY def body (instance or singleton) of the enclosing class,
        # because Ruby cvars are shared across both facets. The resulting table is seeded into both instance and
        # singleton method bodies through `Scope#class_cvars_for`.
        #
        # ADR-116 WD5 — built by {ClassCvarsCollector} on the shared {DeclarationWalk}; `RIGOR_SHADOW_RULE_WALK`
        # checks it against {.legacy_class_cvar_index}.
        def build_class_cvar_index(root, default_scope)
          collector = ClassCvarsCollector.new
          DeclarationWalk.run(root, [collector],
                              DeclarationWalk::Context.root(scope: default_scope, nesting: EMPTY_NESTING))
          DeclarationWalk::Shadow.verified(:class_cvars, default_scope.source_path, collector.table) do
            legacy_class_cvar_index(root, default_scope)
          end
          # Issue #3219 — the per-class census the shadow oracle checks, then joined along each superclass tree.
          collector.hierarchy_table(default_scope)
        end

        # The walker {ClassCvarsCollector} replaced, kept as the shadow harness's oracle until ADR-116 WD5 has
        # ported every table walker onto {DeclarationWalk}.
        def legacy_class_cvar_index(root, default_scope)
          accumulator = {}
          walk_class_cvars(root, [], default_scope, accumulator)
          finished_cvar_census(accumulator)
        end

        # `def_owner` names the class a `def` leaf's cvar writes belong to when `self` is
        # rebound — see {ClassIvarIndex.walk_class_ivars}. `[]` marks a self no name covers.
        def walk_class_cvars(node, qualified_prefix, default_scope, accumulator, def_owner: nil,
                             singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return if walk_cvars_declaration?(node, qualified_prefix, default_scope, accumulator,
                                              def_owner, singleton_cref)
          when Prism::SingletonClassNode
            # The expression evaluates in the enclosing cref; the body's cref is the
            # unnameable singleton class — the marker lifts only at a nameable header.
            walk_class_cvars(node.expression, qualified_prefix, default_scope, accumulator,
                             def_owner: def_owner, singleton_cref: singleton_cref)
            if node.body
              # `self` below `class <<` is the singleton class — `self::`-anchored receivers
              # decline; `@@x` keeps the lexical cref either way, so the body walks ownerless.
              walk_class_cvars(node.body, qualified_prefix, default_scope, accumulator,
                               def_owner: [], singleton_cref: true)
            end
            return
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
               Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
            return if walk_cvars_meta_new?(node, qualified_prefix, default_scope, accumulator,
                                           def_owner, singleton_cref)
          when Prism::DefNode
            # `@@x` inside a `def` resolves through the LEXICAL cref — `Module.nesting` is the
            # same inside a meta-new or eval block, so `def_owner` (the rebound self) must not
            # feed this: `K = Class.new { def m = @@x }` inside `class C` writes `C::@@x`.
            collect_def_cvar_writes(node, qualified_prefix, default_scope, accumulator)
            return
          when Prism::CallNode
            return if walk_cvars_meta_call?(node, qualified_prefix, default_scope, accumulator,
                                            def_owner, singleton_cref)
            return if walk_cvars_eval_call?(node, qualified_prefix, default_scope, accumulator,
                                            def_owner, singleton_cref)
          end

          node.rigor_each_child do |child|
            walk_class_cvars(child, qualified_prefix, default_scope, accumulator,
                             def_owner: def_owner, singleton_cref: singleton_cref)
          end
        end

        # The `K = Class.new { … }` arm of {.walk_class_cvars}: the block's `def` cvar
        # writes belong to the class the write names; its declarations stay lexical.
        def walk_cvars_meta_new?(node, qualified_prefix, default_scope, accumulator,
                                 def_owner, singleton_cref)
          split = DeclarationWalk::Rules.meta_new_block_split(node, qualified_prefix, def_owner, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_class_cvars(part, qualified_prefix, default_scope, accumulator,
                             def_owner: def_owner, singleton_cref: singleton_cref)
          end
          if body
            walk_class_cvars(body, qualified_prefix, default_scope, accumulator,
                             def_owner: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The class/module arm of {.walk_class_cvars}: under an unnameable cref a
        # bare/`self::` header opens `#<singleton>::Name` — ownerless; nameable headers
        # re-anchor at a real cref.
        def walk_cvars_declaration?(node, qualified_prefix, default_scope, accumulator,
                                    def_owner, singleton_cref)
          ctx = DeclarationWalk::Rules.decl_body_context(node, qualified_prefix, def_owner, singleton_cref)
          return false unless ctx

          _self_decl, child_prefix, child_cref = ctx
          return true unless node.body

          collect_body_cvar_writes(node.body, child_cref ? [] : child_prefix,
                                   DeclarationWalk::Rules.scope_entering_declaration(default_scope, node.constant_path),
                                   accumulator)
          walk_class_cvars(node.body, child_cref ? [] : child_prefix,
                           DeclarationWalk::Rules.scope_entering_declaration(default_scope, node.constant_path),
                           accumulator, singleton_cref: child_cref)
          true
        end

        # The bare `Class.new { … }`-family call arm of {.walk_class_cvars}: the block's
        # `def` cvar writes belong to an unnameable class.
        def walk_cvars_meta_call?(node, qualified_prefix, default_scope, accumulator,
                                  def_owner, singleton_cref)
          return false unless DeclarationWalk::Rules.meta_new_constant_rvalue?(node) &&
                              node.block.is_a?(Prism::BlockNode)

          [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
            walk_class_cvars(part, qualified_prefix, default_scope, accumulator,
                             def_owner: def_owner, singleton_cref: singleton_cref)
          end
          if (body = node.block.body)
            walk_class_cvars(body, qualified_prefix, default_scope, accumulator,
                             def_owner: [], singleton_cref: singleton_cref)
          end
          true
        end

        # The eval-family arm of {.walk_class_cvars}: the block's `self` is the receiver for
        # `self::` declarations (`X.class_eval { class self::D; def m = @@x }` reads
        # `X::D::@@x`), while `@@x` writes inside `def`s keep the lexical cref either way.
        def walk_cvars_eval_call?(node, qualified_prefix, default_scope, accumulator,
                                  def_owner, singleton_cref)
          split = DeclarationWalk::Rules.eval_block_split(node, qualified_prefix, def_owner, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_class_cvars(part, qualified_prefix, default_scope, accumulator,
                             def_owner: def_owner, singleton_cref: singleton_cref)
          end
          if body
            walk_class_cvars(body, qualified_prefix, default_scope, accumulator,
                             def_owner: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        def collect_def_cvar_writes(def_node, qualified_prefix, default_scope, accumulator)
          return if def_node.body.nil? || qualified_prefix.empty?

          class_name = qualified_prefix.join("::")
          body_scope = CensusScope.census_body_scope(default_scope, qualified_prefix,
                                                     Type::Combinator.nominal_of(class_name))
          gather_cvar_writes(def_node.body, body_scope, class_name, accumulator, join_only: false)
        end

        # Issue #3204 — the writes a `class` / `module` body makes outside its `def`s (`@@x = nil` at the top of
        # the body, in a block or a `class << self` there): Ruby resolves each through the body's lexical cref,
        # so it is the same cvar a sibling `def` reads. Such a write only joins an entry a `def` body's write of
        # the same class creates: the census misses most of the other ways a cvar is written
        # (`||=`, `+=`, an including class, a subclass, another file, `class_variable_set` from outside), so a
        # body-only seed would be precise where Ruby's value is not, and stays unbound. The rvalue is typed with
        # the class itself as `self`. The gather stops at `def`, `class` and `module`, which their own events enter.
        def collect_body_cvar_writes(body, qualified_prefix, default_scope, accumulator)
          return if body.nil? || qualified_prefix.empty?

          class_name = qualified_prefix.join("::")
          body_scope = CensusScope.census_body_scope(default_scope, qualified_prefix,
                                                     Type::Combinator.singleton_of(class_name))
          gather_cvar_writes(body, body_scope, class_name, accumulator, join_only: true)
        end

        def gather_cvar_writes(node, scope, class_name, accumulator, join_only:)
          return unless node.is_a?(Prism::Node)

          if node.is_a?(Prism::ClassVariableWriteNode)
            record_cvar_write(accumulator, class_name, node.name,
                              EmptySeed.erase(node.value, scope.type_of(node.value)), join_only: join_only)
          end
          record_reflective_cvar_write(node, scope, class_name, accumulator) if node.is_a?(Prism::CallNode)
          # Issue #1217 — `rescue => @@c` / `for @@c in xs` write through a target node. Each enters as the
          # `Dynamic[top]` floor, the rescue reference too. The floor dates from when the census keyed each class
          # alone, so a superclass's `@@c = nil` was not in a subclass's entry; #3219's {CvarHierarchy} join now
          # adds it, and the floor is kept.
          ClassIvarIndex::BindingTargets.names(node, Prism::ClassVariableTargetNode).each do |name|
            record_cvar_write(accumulator, class_name, name, Type::Combinator.untyped, join_only: join_only)
          end
          return if ClassIvarIndex::IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

          node.rigor_each_child { |c| gather_cvar_writes(c, scope, class_name, accumulator, join_only: join_only) }
        end

        # Issue #3204 — `class_variable_set(:@@x, v)` on an implicit or `self` receiver writes the cvar a sibling
        # `def` reads, as `@@x = v` does. It only joins, like a class-body write: a dynamic name, a `send`, an
        # explicit receiver or another file may write the same cvar unseen.
        def record_reflective_cvar_write(node, scope, class_name, accumulator)
          return unless node.name == :class_variable_set && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))

          args = node.arguments&.arguments
          return unless args&.size == 2

          name_node, value = args
          # A name that is not a cvar's never meets a `def` write's entry, so the join drops it.
          name = name_node.unescaped if name_node.is_a?(Prism::SymbolNode) || name_node.is_a?(Prism::StringNode)
          return unless name

          record_cvar_write(accumulator, class_name, name.to_sym, EmptySeed.erase(value, scope.type_of(value)),
                            join_only: true)
        end

        # A class-body or `class_variable_set` write no `def` body's write has met yet (issue #3204): it joins an
        # entry a creating write makes later, and {.finished_cvar_census} drops it when none does.
        JoinOnlyCvarWrite = Data.define(:type)

        # Every census write unions with what the entry already holds, so the seed does not depend on the order of
        # the writes. A `join_only` write (a class or module body's, or `class_variable_set`) never creates an entry
        # on its own: it is held as a {JoinOnlyCvarWrite} until a `def` body's write of the same cvar arrives.
        def record_cvar_write(accumulator, class_name, name, type, join_only:)
          entries = (accumulator[class_name] ||= {})
          existing = entries[name]
          entries[name] =
            if existing.nil? then join_only ? JoinOnlyCvarWrite.new(type) : type
            elsif existing.is_a?(JoinOnlyCvarWrite)
              joined = Type::Combinator.union(existing.type, type)
              join_only ? JoinOnlyCvarWrite.new(joined) : joined
            else Type::Combinator.union(existing, type)
            end
        end

        # The census as the discovery index holds it: each cvar only joining writes reached dropped, each class's
        # entry frozen, then the whole.
        def finished_cvar_census(accumulator)
          accumulator.filter_map do |class_name, entries|
            kept = entries.reject { |_, type| type.is_a?(JoinOnlyCvarWrite) }
            [class_name, kept.freeze] unless kept.empty?
          end.to_h.freeze
        end

        private_class_method :legacy_class_cvar_index, :walk_class_cvars, :walk_cvars_meta_new?,
                             :walk_cvars_declaration?, :walk_cvars_meta_call?, :walk_cvars_eval_call?,
                             :gather_cvar_writes, :record_reflective_cvar_write, :record_cvar_write
      end
    end
  end
end
