# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../anonymous_meta_class"
require_relative "../declaration_walk/traversal"
require_relative "../declaration_walk/rules"
require_relative "superclasses_collector"
require_relative "member_layouts_collector"
require_relative "def_nestings_collector"
require_relative "factory_call_resolver"
require_relative "constant_tables"

module Rigor
  module Inference
    module ScopeIndexer
      # The tables ONE shared {DeclarationWalk} builds for a file (ADR-116 WD5), moved out of `scope_indexer.rb`
      # whole (ADR-116 WD9, U4): the as-written superclass table with its header-nesting twin, the def-nesting
      # table, and the `Data.define` and `Struct.new` member layouts. {.declaration_walk_tables} is the entry
      # `scope_indexer.rb` calls, once per file on each of its two index paths: it runs {SuperclassesCollector},
      # {MemberLayoutsCollector} and {DefNestingsCollector}, each a sibling file, in one descent.
      #
      # Seven more functions are public, because another file calls each. The collectors call the four recorders:
      # {.record_declaration_ancestry} and {.record_anonymous_meta_superclass} the first,
      # {.record_data_member_layout} and {.record_struct_member_layout} the second. {CvarHierarchy} asks
      # {.recorded_ancestor_name} for a superclass as the table spells it. And `ScopeIndexer.record_meta_member_names`
      # asks {.meta_member_names} and {.meta_members_open?} for the member list of a factory call: that reading
      # moved here with the layout tables, which are its table, so that the module called back three functions and
      # not five. The rest is private: a builder per table that runs its collector alone, for the specs
      # ({.build_superclass_tables}, {.build_def_nestings}, {.build_data_member_layouts},
      # {.build_struct_member_layouts}); the `verified_*` step that hands each table to `RIGOR_SHADOW_RULE_WALK`;
      # and the walkers the collectors replaced, kept as that check's oracles ({.legacy_superclass_tables},
      # {.legacy_def_nestings}, {.legacy_data_member_layouts}, {.legacy_struct_member_layouts} and their arms).
      #
      # It asks {DeclarationWalk::Rules} for each declaration context, and two sibling files it requires for what
      # were the second and third functions it called back, until #3400 moved them: {FactoryCallResolver} for the
      # factory call an expression unwinds to, and {ConstantTables} for which block rebinds `self`
      # (`ConstantTables.rebound_block_self`, for the mixin names a header nesting is keyed by). It calls one
      # function left in `scope_indexer.rb`: `ScopeIndexer.add_header_nesting` (the insert of the header-nesting
      # table, which stays beside the merges the cross-file fold shares with it). `scope_indexer.rb` requires this
      # file, and this file does not require it back. It reads `ScopeIndexer::EMPTY_NESTING`, `EMPTY_PREFIX`,
      # `RECEIVER_EVAL_CALLS` and `MIXIN_CALL_NAMES` lexically, as {NodePropagation} reads the indexer's constants,
      # and `ConstantTables.rebound_block_self` reads `RECEIVER_EVAL_CALLS` and `OPAQUE_SELF` the same way. So the
      # file loads alone, and until `scope_indexer.rb` has loaded only the functions that reach none of those six
      # names answer.
      module SharedWalkTables # rubocop:disable Metrics/ModuleLength
        module_function

        # The literal Symbol member names of a `Data.define` / `Struct.new` call ({.meta_member_positionals}). A
        # splatted argument contributes none; {.meta_members_open?} says the list is then incomplete.
        def meta_member_names(call_node)
          meta_member_positionals(call_node).filter_map { |arg| arg.unescaped.to_sym if arg.is_a?(Prism::SymbolNode) }
        end

        # Issue #2968 — whether a `Data.define` / `Struct.new` call's member list holds a splat, so its members are not
        # all literal and the reader set is unknown. A layout table or a closed reader set must not be built from it.
        def meta_members_open?(call_node)
          meta_member_positionals(call_node).any?(Prism::SplatNode)
        end

        # The member arguments of a `Data.define` / `Struct.new` call. For `Struct.new` the trailing `keyword_init:`
        # hash is stripped ({DeclarationWalk::Rules.struct_new_positionals}). A leading class-name String
        # (`Struct.new("Named", :a)`) is neither a Symbol nor a splat, so it is no member and does not open the list.
        def meta_member_positionals(call_node)
          raw = call_node.arguments&.arguments || []
          DeclarationWalk::Rules.struct_new_call?(call_node) ? DeclarationWalk::Rules.struct_new_positionals(raw) : raw
        end

        # Issue #681 — `{Prism::DefNode => Module.nesting}` for every `def` the file declares inside a class or
        # module body, keyed by node IDENTITY so the answer follows the DECLARATION rather than the class a
        # call happens to dispatch on. `Inference::ExpressionTyper#build_user_method_body_scope` rebuilds a
        # callee's body scope from the RECEIVER'S TYPE alone when it needs that callee's return, so unlike the
        # census scopes (#692) there is no prefix in hand to stamp: recording the chain where the declaration is
        # indexed is what makes the re-walk and the declaration walk agree BY CONSTRUCTION, which is the
        # argument #685 used to make {Reflection.lexical_nesting_chain} the single owner.
        #
        # Keyed on the def node and not on `(class, method)` because an inherited body is re-walked with the
        # SUBCLASS as receiver: `class Admin::CompactBase` declares `make`, `module Admin; class Child <
        # CompactBase` calls it, and the bare `Post` inside `make` names `::Post` — the constant the compact
        # declaration that OWNS the body reaches, not the one the receiver's spelling would suggest.
        #
        # Not a leaf of the fused methods/def-nodes walk: it needs the CHAIN threaded, which the fused walk does
        # not carry (a singleton-class body and a `Class.new` block body both push a qualified prefix while
        # pushing no `Module.nesting` entry). {DefNestingsCollector} declines at every `Prism::DefNode`, so a
        # def-dense file pays only the declaration spine.
        #
        # ADR-116 WD5 — production builds this table in {.declaration_walk_tables}' shared run, and nothing in
        # `lib` calls this builder. It runs the collector alone and stays for the specs, which compare it with
        # the shared run; `RIGOR_SHADOW_RULE_WALK` checks it against {.legacy_def_nestings}.
        def build_def_nestings(root)
          collector = DefNestingsCollector.new
          DeclarationWalk.run(root, [collector], superclass_walk_root(nil))
          verified_def_nestings(root, collector.table)
        end

        def verified_def_nestings(root, table, source_path = nil)
          DeclarationWalk::Shadow.verified(:def_nestings, source_path, table) { legacy_def_nestings(root) }
        end

        # The walker {DefNestingsCollector} replaced, kept as the shadow harness's oracle until ADR-116 WD5 has
        # ported every table walker onto {DeclarationWalk}.
        def legacy_def_nestings(root)
          accumulator = {}.compare_by_identity
          walk_def_nestings(root, EMPTY_NESTING, accumulator)
          accumulator.freeze
        end

        # Records `nesting` for every `def` reachable from `node`. Only a `class` / `module` keyword pushes an
        # entry (qualified against the entry already on top, so a compact `class Admin::X` contributes ONE);
        # every other body — a singleton class, a `Class.new` / `Module.new` block, any other block — inherits
        # the chain unchanged, because Ruby pushes no cref for them.
        #
        # Issue #716 — a top-level `def` records the EMPTY chain, and that is a recorded answer rather than the
        # absence of one. Ruby's `Module.nesting` in a top-level body IS `[]`, so `def helper = Post.new` names
        # `::Post` wherever it is later called from; recording nothing left
        # {Reflection.lexical_nesting_chain} peeling the CALLER's qualified name, which answered `Admin::Post`
        # for a call made from inside `module Admin`. The table is keyed by node identity and populated only by
        # this walk, so "present with `[]`" (walked, and top level) stays distinguishable from "absent" (no
        # declaration walk built this scope — a plugin-constructed scope, an anonymous `Class.new` re-entered
        # through `Scope#evaluate`), which keeps the peel where it is still the only available answer.
        # `self_base` names a rebound `self` for `self::`-anchored headers — a meta-new
        # block's class; `[]` marks a self no name covers.
        def walk_def_nestings(node, nesting, accumulator, self_base: nil, singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return walk_def_nesting_declaration(node, nesting, accumulator, self_base,
                                                singleton_cref)
          when Prism::SingletonClassNode
            # The expression evaluates in the enclosing cref; the body's cref is unnameable —
            # and `self` below it is the singleton class, which `self::` headers decline on.
            walk_def_nestings(node.expression, nesting, accumulator,
                              self_base: self_base, singleton_cref: singleton_cref)
            if node.body
              walk_def_nestings(node.body, nesting, accumulator,
                                self_base: EMPTY_PREFIX, singleton_cref: true)
            end
            return
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathOrWriteNode
            return if walk_def_nesting_meta_new?(node, nesting, accumulator, self_base,
                                                 singleton_cref)
          when Prism::DefNode
            accumulator[node] = nesting unless nesting.nil?
            return
          when Prism::CallNode
            return if walk_def_nesting_eval?(node, nesting, accumulator, self_base, singleton_cref)
          end

          node.rigor_each_child do |child|
            walk_def_nestings(child, nesting, accumulator,
                              self_base: self_base, singleton_cref: singleton_cref)
          end
        end

        # The class/module arm of {.walk_def_nestings}: under an unnameable cref a
        # bare/`self::` header pushes `#<singleton>::Name` — a rung nothing can spell — so
        # the chain keeps what it had rather than filing a fabricated `C::D`; nameable
        # headers re-anchor at a real cref.
        def walk_def_nesting_declaration(node, nesting, accumulator, self_base, singleton_cref)
          return unless node.body

          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path, self_base)
          child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
          child_nesting =
            if child_cref
              nesting
            elsif self_decl
              [self_decl.join("::"), *nesting].freeze
            else
              Source::ConstantPath.pushed_nesting(nesting, node.constant_path)
            end
          walk_def_nestings(node.body, child_nesting, accumulator, singleton_cref: child_cref)
        end

        # The meta-new arm of {.walk_def_nestings}: the block rebinds only `self` — a
        # `self::` header inside anchors on the class the write names (`K::SX` below
        # `K = Class.new`), while `Module.nesting`, the table's payload, stays lexical.
        def walk_def_nesting_meta_new?(node, nesting, accumulator, self_base, singleton_cref)
          split = DeclarationWalk::Rules.meta_new_block_split(node, nesting_lexical_prefix(nesting), self_base,
                                                              singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_def_nestings(part, nesting, accumulator, self_base: self_base,
                                                          singleton_cref: singleton_cref)
          end
          if body
            walk_def_nestings(body, nesting, accumulator, self_base: body_self,
                                                          singleton_cref: singleton_cref)
          end
          true
        end

        # The eval-family arm of {.walk_def_nestings}: `self` rebinds to the receiver for
        # `self::` headers while `Module.nesting` stays lexical. `instance_eval` belongs
        # here too — it moves `self` for constant anchoring even though its `def`s bind
        # on the receiver's singleton.
        def walk_def_nesting_eval?(node, nesting, accumulator, self_base, singleton_cref)
          return false unless node.block.is_a?(Prism::BlockNode) &&
                              RECEIVER_EVAL_CALLS.include?(node.name)

          [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
            walk_def_nestings(part, nesting, accumulator, self_base: self_base,
                                                          singleton_cref: singleton_cref)
          end
          lexical = nesting_lexical_prefix(nesting)
          self_prefix = self_base || lexical
          unnameable = DeclarationWalk::Rules.unnameable_eval_self?(false, self_base, lexical, singleton_cref)
          eval_self = DeclarationWalk::Rules.eval_receiver_prefix(node, self_prefix, lexical,
                                                                  unnameable_self: unnameable) || []
          if (body = node.block.body)
            walk_def_nestings(body, nesting, accumulator, self_base: eval_self,
                                                          singleton_cref: singleton_cref)
          end
          true
        end

        # The innermost lexical cref a def-nesting rung list names, as a prefix array — the
        # shape {DeclarationWalk::Rules.meta_new_child_prefix} and {DeclarationWalk::Rules.eval_receiver_prefix} take.
        def nesting_lexical_prefix(nesting)
          nesting&.first ? nesting.first.split("::") : []
        end

        # ADR-24 slice 2 — per-class table mapping a fully qualified user class to its superclass name AS WRITTEN at the
        # `class Foo < Bar` declaration. Only constant superclasses are recorded (`class Foo < Struct.new(...)` and
        # other non-constant superclasses produce no entry). The as-written name is resolved to a qualified class at the
        # call site against the nesting the declaration's HEADER sits in — see {Scope#ancestor_name_candidates}, which
        # reads the second table this walk builds.
        #
        # Issue #682 — `header_nestings` maps the same qualified class name to that nesting: `Module.nesting` where the
        # `class` / `module` KEYWORD is written, which is the body's chain minus the declaration's own entry. It is
        # recorded here, with the walk's prefix in hand, because it is unrecoverable afterwards: `class Admin::Widget`
        # and `module Admin; class Widget` render the identical `"Admin::Widget"`, and an ancestor name is resolved in
        # the enclosing cref — `[]` for the first spelling, `["Admin"]` for the second. A class reopened under two
        # spellings keeps the LAST one walked, matching how `superclasses` itself merges.
        #
        # ADR-116 WD5 — built by {SuperclassesCollector} on the shared {DeclarationWalk}, following the two
        # legacy variants it declares; `RIGOR_SHADOW_RULE_WALK` checks both tables against
        # {.legacy_superclass_tables}. Production builds both in {.declaration_walk_tables}' shared run, and
        # nothing in `lib` calls this builder: it runs the collector alone and stays for the specs, which
        # compare it with the shared run.
        #
        # @return the `[superclasses, header_nestings]` pair
        def build_superclass_tables(root, source_path = nil)
          collector = SuperclassesCollector.new
          DeclarationWalk.run(root, [collector], superclass_walk_root(source_path))
          verified_superclass_tables(root, source_path, collector.tables)
        end

        # The root context the superclass tables are walked from: the ancestry nesting starts empty and the
        # anonymous-class key carries the file's path.
        def superclass_walk_root(source_path, scope: nil)
          DeclarationWalk::Context.root(scope: scope, nesting: EMPTY_NESTING, source_path: source_path)
        end

        # `tables` once the shadow harness has compared them with the legacy walker's, when it is on.
        def verified_superclass_tables(root, source_path, tables)
          DeclarationWalk::Shadow.verified(:superclass_tables, source_path, tables) do
            legacy_superclass_tables(root, source_path)
          end
        end

        # The walker {SuperclassesCollector} replaced, kept as the shadow harness's oracle until ADR-116 WD5 has
        # ported every table walker onto {DeclarationWalk}.
        def legacy_superclass_tables(root, source_path = nil)
          accumulator = { superclasses: {}, header_nestings: {} }
          walk_class_superclasses(root, [], accumulator, source_path)
          [accumulator[:superclasses].freeze, accumulator[:header_nestings].freeze]
        end

        # ADR-116 WD5 — the file's superclass, header-nesting, def-nesting and member-layout tables from ONE
        # shared {DeclarationWalk}: the file is descended once for all of them, where the legacy walkers
        # descended it once per table. `RIGOR_SHADOW_RULE_WALK` checks each table against its legacy walker.
        #
        # @return `{ superclasses:, header_nestings:, def_nestings:, data_member_layouts:, struct_member_layouts: }`
        def declaration_walk_tables(root, source_path = nil)
          superclasses = SuperclassesCollector.new
          layouts = MemberLayoutsCollector.new
          def_nestings = DefNestingsCollector.new
          DeclarationWalk.run(root, [superclasses, layouts, def_nestings], superclass_walk_root(source_path))
          supers, header_nestings = verified_superclass_tables(root, source_path, superclasses.tables)
          data, struct = verified_member_layouts(root, layouts.tables, source_path)
          { superclasses: supers, header_nestings: header_nestings,
            def_nestings: verified_def_nestings(root, def_nestings.table, source_path),
            data_member_layouts: data, struct_member_layouts: struct }
        end

        # `self_base` names a rebound `self` for `self::`-anchored headers — a meta-new
        # block's class; `[]` marks a self no name covers.
        def walk_class_superclasses(node, qualified_prefix, accumulator, source_path = nil,
                                    nesting = EMPTY_NESTING, self_base: nil, singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::CallNode
            return if walk_superclass_eval_call?(node, qualified_prefix, accumulator, source_path,
                                                 nesting, self_base, singleton_cref)

            record_anonymous_meta_superclass(node, accumulator[:superclasses], source_path)
          when Prism::ClassNode, Prism::ModuleNode
            return if walk_superclass_declaration?(node, qualified_prefix, accumulator, nesting,
                                                   self_base, singleton_cref)
          when Prism::SingletonClassNode
            # The expression evaluates in the enclosing cref; the body's cref is unnameable.
            return walk_singleton_superclasses(node, qualified_prefix, accumulator, source_path,
                                               nesting, self_base, singleton_cref)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
               Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
            return if walk_superclass_meta_new?(node, qualified_prefix, accumulator, source_path,
                                                nesting, self_base, singleton_cref)
          end

          node.rigor_each_child do |child|
            walk_class_superclasses(child, qualified_prefix, accumulator, source_path, nesting,
                                    self_base: self_base, singleton_cref: singleton_cref)
          end
        end

        # The eval-family arm of {.walk_class_superclasses}: `self::` headers anchor on the
        # receiver — `X.class_eval { class self::D < S }` files `X::D`'s ancestry — while bare
        # headers and the nesting rungs stay lexical.
        def walk_superclass_eval_call?(node, qualified_prefix, accumulator, source_path, nesting,
                                       self_base, singleton_cref)
          split = DeclarationWalk::Rules.eval_block_split(node, qualified_prefix, self_base, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_class_superclasses(part, qualified_prefix, accumulator, source_path, nesting,
                                    self_base: self_base, singleton_cref: singleton_cref)
          end
          if body
            walk_class_superclasses(body, qualified_prefix, accumulator, nil, nesting,
                                    self_base: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The `K = Class.new { … }` arm of {.walk_class_superclasses}: the block's `self` is the
        # class the write names; its declarations stay lexical.
        def walk_superclass_meta_new?(node, qualified_prefix, accumulator, source_path, nesting,
                                      self_base, singleton_cref)
          split = DeclarationWalk::Rules.meta_new_block_split(node, qualified_prefix, self_base, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_class_superclasses(part, qualified_prefix, accumulator, source_path, nesting,
                                    self_base: self_base, singleton_cref: singleton_cref)
          end
          if body
            walk_class_superclasses(body, qualified_prefix, accumulator, nil, nesting,
                                    self_base: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The class/module arm of {.walk_class_superclasses}: under an unnameable cref a
        # bare/`self::` header opens `#<singleton>::Name` — ancestry/nesting facts for it
        # would publish under a `C::D` MRI never creates, so they are skipped and the body
        # walks ownerless; nameable headers re-anchor at a real cref.
        def walk_superclass_declaration?(node, qualified_prefix, accumulator, nesting,
                                         self_base, singleton_cref)
          ctx = DeclarationWalk::Rules.decl_body_context(node, qualified_prefix, self_base, singleton_cref)
          return false unless ctx

          self_decl, child_prefix, child_cref = ctx
          record_declaration_ancestry(node, nesting, child_prefix, accumulator) unless child_cref
          child_nesting =
            if child_cref
              nesting
            elsif self_decl
              [self_decl.join("::"), *nesting].freeze
            else
              Source::ConstantPath.pushed_nesting(nesting, node.constant_path) || nesting
            end
          return true unless node.body

          walk_class_superclasses(node.body, child_cref ? [] : child_prefix, accumulator, nil,
                                  child_nesting, singleton_cref: child_cref)
          true
        end

        def walk_singleton_superclasses(node, qualified_prefix, accumulator, source_path, nesting,
                                        self_base, singleton_cref)
          walk_class_superclasses(node.expression, qualified_prefix, accumulator, source_path,
                                  nesting, self_base: self_base, singleton_cref: singleton_cref)
          return unless node.body

          # `self` below `class <<` is the singleton class — `self::` headers decline.
          walk_class_superclasses(node.body, qualified_prefix, accumulator, source_path,
                                  nesting, self_base: EMPTY_PREFIX, singleton_cref: true)
        end

        # One declaration's two ancestry facts: the as-written superclass name (classes only), and the
        # `Module.nesting` its header is written in. `nesting` is the chain in force OUTSIDE the header — the
        # header is evaluated before the body is entered, so the declaration's own entry is not on the ladder
        # its superclass name walks — which is why the walk pushes only when it recurses into the body. The
        # chain is threaded rather than derived from the enclosing prefix because a rooted header resets that
        # prefix without resetting Ruby's nesting ([#708](https://github.com/rigortype/rigor/issues/708)).
        def record_declaration_ancestry(node, nesting, child_prefix, accumulator)
          full = child_prefix.join("::")
          names = declared_ancestor_names(node)
          ScopeIndexer.add_header_nesting(accumulator[:header_nestings], full, nesting, names) if names
          return unless node.is_a?(Prism::ClassNode)

          accumulator[:superclasses][full] = recorded_ancestor_name(node.superclass) if node.superclass
        end

        # Issue #722 residue 1 / #637 — the recorded ancestor name, carrying the ROOTED marker when the site
        # wrote one. `Source::ConstantPath.qualified_name` renders segments only, so `class Rooted < ::Base`
        # recorded the same `"Base"` a bare `< Base` does, and the resolver then walked the enclosing nesting
        # and answered `A::Base` — a class Ruby never looks at, on a spelling whose whole point is that it
        # does not.
        #
        # The marker rides the existing table's VALUE rather than a new table. It is still a String, so the
        # per-file index, the cross-file fold and the ADR-85 seed bundle carry it unchanged; the three
        # resolvers that read it strip and anchor. `IncrementalSnapshot::SCHEMA` is bumped anyway, because an
        # older blob's un-rooted value is indistinguishable from "not rooted" and a warm run would keep the
        # pre-fix answer for every unchanged file.
        def recorded_ancestor_name(node)
          name = Source::ConstantPath.qualified_name(node)
          return name if name.nil? || !Source::ConstantPath.rooted?(node)

          "::#{name}"
        end

        # The ancestor names this declaration SITE writes — the superclass in its header, and every mixin
        # argument in its own body — or nil when the site writes none. Only a site that writes one
        # contributes a header nesting, and the names are what key it: Ruby resolves each ancestor name in
        # the cref of the site that WROTE it, and a class's sites need not agree on that cref.
        #
        # Issue #708's review: a per-CLASS union of every site's chain is wrong for a rooted reopen inside
        # another namespace. `class ::Foo; def extra = 1; end` written in `module Outer` contributed `["Outer"]`
        # to `Foo`, and the ancestor rung then resolved `Foo`'s superclass `Base` as `Outer::Base` — a class
        # Ruby never looks at, ahead of the right one, on a site that named no ancestor at all. A site that
        # writes no ancestor name has no ancestor for its cref to govern, so it has nothing to say here.
        #
        # Issue #728: dropping those sites was necessary and not sufficient. When the rooted reopen genuinely
        # names a mixin — `class ::Foo; include Helper; end` in `module Outer` — the site is recorded, and a
        # per-class union then hands its `["Outer"]` to `Foo`'s superclass `Base` as well, which is the same
        # `Outer::Base` on the same repro. Keying by the written name is what separates them: `Base` resolves
        # in the empty chain of the top-level site that wrote `< Base`, `Helper` in the `["Outer"]` chain of
        # the site that wrote `include Helper`, which is what Ruby does for each independently.
        #
        # This keeps what the union was FOR. It was added because last-writer-wins let one rails TEST file
        # reopening `ActiveRecord::Relation` compactly beat the library declaration, costing the class all nine
        # of its `include`d modules; that reopen writes no ancestor name either, so it contributes nothing
        # rather than winning — the protection comes from the recording rule instead of from a merge rule.
        #
        # The mixin scan counts only a call whose `self` is the declaration itself, so it stops at every construct that
        # rebinds `self`: a nested `class` / `module` (that body's calls belong to the nested class), a `class << self`
        # body, and a block `ConstantTables.rebound_block_self` classifies as rebinding — the `Class.new` / `Module.new`
        # / `Struct.new` / `Data.define` and `class_eval` family. An `include` written in any of those attaches to
        # something other than this class, so treating it as this site's ancestor name reinstates exactly the defect
        # above with a different spelling. {ScopeIndexer.walk_class_includes} classifies the same shapes the same way
        # since [#749](https://github.com/rigortype/rigor/pull/749), so the two walks agree on which site owns a mixin.
        #
        # It stays structural rather than exhaustive: `self.include M` and `send(:include, M)` are recorded by neither
        # walk, so the class's ancestry agrees. `Recv.class_eval { include M }` is the one shape where they diverge in
        # the surviving direction — the includes walk names `Recv`, this one cannot see the site from `Recv`'s own
        # declaration — and that is what {ScopeIndexer.add_header_nesting}'s unkeyed entry answers.
        def declared_ancestor_names(node)
          names = []
          superclass = node.is_a?(Prism::ClassNode) ? node.superclass : nil
          if superclass
            recorded = recorded_ancestor_name(superclass)
            names << recorded if recorded
          end
          body = node.body
          mixin = body ? collect_mixin_names(body, names) : false
          return names if superclass || mixin

          nil
        end

        # Appends each mixin argument this body names to `names`, and answers whether it writes a mixin call at all — a
        # `include some_method` writes one while naming nothing renderable, and the site still owns a chain for the
        # names it does write. Arguments are rendered exactly as {ScopeIndexer.record_mixin_call} renders them, so a
        # name recorded here is the same String the includes table stores and the resolver asks for.
        def collect_mixin_names(node, names)
          return false unless node.is_a?(Prism::Node)
          return false if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) ||
                          node.is_a?(Prism::SingletonClassNode)

          found = mixin_call?(node)
          record_mixin_names(node, names) if found
          rebinds = ConstantTables.rebound_block_self(node, EMPTY_PREFIX)
          node.rigor_each_child do |child|
            next if rebinds && child.is_a?(Prism::BlockNode)

            found = true if collect_mixin_names(child, names)
          end
          found
        end

        def mixin_call?(node)
          node.is_a?(Prism::CallNode) && node.receiver.nil? && MIXIN_CALL_NAMES.include?(node.name)
        end

        def record_mixin_names(node, names)
          node.arguments&.arguments&.each do |arg|
            mod = Source::ConstantPath.qualified_name(arg)
            names << mod if mod
          end
        end

        # #319 — `Class.new(Parent) do ... end` names its superclass in the first positional. Recording it under the
        # call site's anonymous name keeps `Parent`'s surface reachable from the block body (whose `self_type` is now
        # `Singleton[<anonymous>]`) and from an instance of the resulting class, so giving the anonymous class an
        # identity does not cost the inheritance the old `Singleton[Parent]` answer carried for free.
        def record_anonymous_meta_superclass(call_node, accumulator, source_path)
          return unless AnonymousMetaClass.block_form_receiver(call_node) == :Class

          arg = call_node.arguments&.arguments&.first
          return if arg.nil?

          # Issue #722 residue 1 — deliberately NOT marked rooted here, unlike the `class X < ::Parent`
          # header. Marking it changed nothing observable: `Made = Class.new(::Base)` inside a namespace that
          # shadows `Base` still resolved the shadow, so the anonymous class's ancestry is reached by a path
          # that does not read this value, and shipping a marker no resolver honours would be a change with
          # no gate. The residue stays on #722 with that finding attached.
          superclass = Source::ConstantPath.qualified_name(arg)
          return if superclass.nil?

          name = AnonymousMetaClass.name_for(call_node, source_path)
          accumulator[name] = superclass if name
        end

        # ADR-48 — per qualified class name -> ordered `Data.define` member-name list, for both the named-subclass form
        # (`class Point < Data.define(:x, :y)`) and the constant-assigned form (`Point = Data.define(:x, :y)`). Only
        # `Data.define` is recorded: `Struct.new` instances are mutable, so member-value folding would be unsound
        # (the Struct sibling table is {.build_struct_member_layouts}, ADR-48 § "Struct follow-up"). Consumed by
        # {Inference::MethodDispatcher::DataFolding} via {Scope#data_member_layout}.
        #
        # ADR-116 WD5 — built with its Struct sibling by {MemberLayoutsCollector}. Production builds both in
        # {.declaration_walk_tables}' shared run, and nothing in `lib` calls this builder: it stays for the specs,
        # and walks both layout tables to return this one.
        def build_data_member_layouts(root)
          member_layout_tables(root).first
        end

        # `[data_member_layouts, struct_member_layouts]` from a {MemberLayoutsCollector} run of its own, checked by
        # `RIGOR_SHADOW_RULE_WALK` against the two legacy walkers. Spec-only, like the two builders on it.
        def member_layout_tables(root)
          collector = MemberLayoutsCollector.new
          DeclarationWalk.run(root, [collector], superclass_walk_root(nil))
          verified_member_layouts(root, collector.tables)
        end

        def verified_member_layouts(root, tables, source_path = nil)
          DeclarationWalk::Shadow.verified(:member_layouts, source_path, tables) do
            [legacy_data_member_layouts(root), legacy_struct_member_layouts(root)]
          end
        end

        # The walker {MemberLayoutsCollector} replaced for the `Data.define` table, kept as the shadow harness's
        # oracle until ADR-116 WD5 has ported every table walker onto {DeclarationWalk}.
        def legacy_data_member_layouts(root)
          accumulator = {}
          walk_data_member_layouts(root, [], accumulator)
          accumulator.freeze
        end

        # `self_base` names a rebound `self` for `self::`-anchored declarations and write
        # targets — a meta-new block's class; `[]` marks a self no name covers.
        def walk_data_member_layouts(node, qualified_prefix, accumulator, self_base: nil,
                                     singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return walk_layout_declaration(node, qualified_prefix, accumulator, self_base,
                                           singleton_cref, :data)
          when Prism::SingletonClassNode
            # The expression evaluates in the enclosing cref; the body's cref is unnameable.
            return walk_singleton_member_layouts(node, qualified_prefix, accumulator,
                                                 :walk_data_member_layouts, self_base,
                                                 singleton_cref)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathOrWriteNode
            # A meta-new constant write under an unnameable cref lands on the singleton's own
            # table unless it is a path write — declining a bare target rather than keying
            # the block's class by the lexical prefix.
            unless singleton_cref && !DeclarationWalk::Rules.meta_new_path_target_nameable?(node, self_base)
              child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, self_base)
            end
            if child_prefix
              record_data_member_layout(accumulator, child_prefix, DeclarationWalk::Rules.meta_new_rvalue(node))
            end
            return if walk_data_layout_meta_new?(node, qualified_prefix, accumulator,
                                                 self_base, singleton_cref)
          when Prism::CallNode
            return if walk_member_layout_eval_call?(node, qualified_prefix, accumulator,
                                                    self_base, singleton_cref,
                                                    :walk_data_member_layouts)
          end

          node.rigor_each_child do |child|
            walk_data_member_layouts(child, qualified_prefix, accumulator,
                                     self_base: self_base, singleton_cref: singleton_cref)
          end
        end

        # The `K = Data.define { … }`-family arm of {.walk_data_member_layouts}: the
        # factory call's receiver and arguments keep the enclosing context; the block's
        # `self` is the class the write names.
        def walk_data_layout_meta_new?(node, qualified_prefix, accumulator, self_base,
                                       singleton_cref)
          split = DeclarationWalk::Rules.meta_new_block_split(node, qualified_prefix, self_base, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_data_member_layouts(part, qualified_prefix, accumulator,
                                     self_base: self_base, singleton_cref: singleton_cref)
          end
          if body
            walk_data_member_layouts(body, qualified_prefix, accumulator,
                                     self_base: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The class/module-declaration arm shared by the member-layout walks: a `class` header can
        # itself be a `Data.define`/`Struct.new` subclass, and under an unnameable cref a bare/`self::`
        # header opens `#<singleton>::Name` — the record is skipped and the body walks ownerless;
        # nameable headers re-anchor at a real cref.
        def walk_layout_declaration(node, qualified_prefix, accumulator, self_base,
                                    singleton_cref, kind)
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path, self_base)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          return unless child_prefix

          child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
          if node.is_a?(Prism::ClassNode) && !child_cref
            record = kind == :data ? :record_data_member_layout : :record_struct_member_layout
            send(record, accumulator, child_prefix, node.superclass, allow_outer_block: false)
          end
          return unless node.body

          walk = kind == :data ? :walk_data_member_layouts : :walk_struct_member_layouts
          send(walk, node.body, child_cref ? [] : child_prefix, accumulator,
               singleton_cref: child_cref)
        end

        # Records `qualified -> [members]` when `expr` is a `Data.define(*Symbol)` call with at least one literal-Symbol
        # member.
        def record_data_member_layout(accumulator, qualified_parts, expr, allow_outer_block: true)
          expr = FactoryCallResolver.resolve_meta_factory_call(expr, allow_outer_block: allow_outer_block)
          return unless expr && DeclarationWalk::Rules.data_define_call?(expr)
          return if meta_members_open?(expr)

          members = meta_member_names(expr)
          return if members.empty?

          accumulator[qualified_parts.join("::")] = members.freeze
        end

        # ADR-48 Struct follow-up — the `Struct.new(...)` sibling of {.build_data_member_layouts}. A separate, additive
        # table so the existing `Data.define` value-shape contract (a bare `[Symbol]`) is untouched: a Struct entry
        # carries `{ members:, keyword_init: }` because the dispatcher needs the flag to fold the matching `.new` call
        # form (positional vs keyword) without manufacturing a wrong map.
        #
        # ADR-116 WD5 — production builds it in {.declaration_walk_tables}' shared run; this builder is spec-only,
        # like {.build_data_member_layouts}.
        def build_struct_member_layouts(root)
          member_layout_tables(root).last
        end

        # The walker {MemberLayoutsCollector} replaced for the `Struct.new` table, kept as the shadow harness's
        # oracle until ADR-116 WD5 has ported every table walker onto {DeclarationWalk}.
        def legacy_struct_member_layouts(root)
          accumulator = {}
          walk_struct_member_layouts(root, [], accumulator)
          accumulator.freeze
        end

        def walk_struct_member_layouts(node, qualified_prefix, accumulator, self_base: nil,
                                       singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return walk_layout_declaration(node, qualified_prefix, accumulator, self_base,
                                           singleton_cref, :struct)
          when Prism::SingletonClassNode
            # The expression evaluates in the enclosing cref; the body's cref is unnameable.
            return walk_singleton_member_layouts(node, qualified_prefix, accumulator,
                                                 :walk_struct_member_layouts, self_base,
                                                 singleton_cref)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathOrWriteNode
            # A meta-new constant write under an unnameable cref lands on the singleton's own
            # table unless it is a path write — declining a bare target rather than keying
            # the block's class by the lexical prefix.
            unless singleton_cref && !DeclarationWalk::Rules.meta_new_path_target_nameable?(node, self_base)
              child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, self_base)
            end
            if child_prefix
              record_struct_member_layout(accumulator, child_prefix, DeclarationWalk::Rules.meta_new_rvalue(node))
            end
            return if walk_struct_layout_meta_new?(node, qualified_prefix, accumulator,
                                                   self_base, singleton_cref)
          when Prism::CallNode
            return if walk_member_layout_eval_call?(node, qualified_prefix, accumulator,
                                                    self_base, singleton_cref,
                                                    :walk_struct_member_layouts)
          end

          node.rigor_each_child do |child|
            walk_struct_member_layouts(child, qualified_prefix, accumulator,
                                       self_base: self_base, singleton_cref: singleton_cref)
          end
        end

        # The `K = Struct.new { … }`-family arm of {.walk_struct_member_layouts}: the
        # factory call's receiver and arguments keep the enclosing context; the block's
        # `self` is the class the write names.
        def walk_struct_layout_meta_new?(node, qualified_prefix, accumulator, self_base,
                                         singleton_cref)
          split = DeclarationWalk::Rules.meta_new_block_split(node, qualified_prefix, self_base, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_struct_member_layouts(part, qualified_prefix, accumulator,
                                       self_base: self_base, singleton_cref: singleton_cref)
          end
          if body
            walk_struct_member_layouts(body, qualified_prefix, accumulator,
                                       self_base: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The eval-family arm shared by the two member-layout walks: the call's receiver and
        # arguments keep the enclosing context while the block body's `self` is the receiver —
        # a named receiver re-anchors `self::` headers to a real class even under `class <<`;
        # a bare/`self` receiver keeps the enclosing (possibly unnameable) self.
        def walk_member_layout_eval_call?(node, qualified_prefix, accumulator, self_base,
                                          singleton_cref, walk)
          return false unless DeclarationWalk::Rules.receiver_eval_call?(node)

          [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
            send(walk, part, qualified_prefix, accumulator,
                 self_base: self_base, singleton_cref: singleton_cref)
          end
          unnameable = DeclarationWalk::Rules.unnameable_eval_self?(false, self_base, qualified_prefix, singleton_cref)
          eval_self = DeclarationWalk::Rules.eval_receiver_prefix(node, self_base || qualified_prefix, qualified_prefix,
                                                                  unnameable_self: unnameable) || []
          if (body = node.block.body)
            send(walk, body, qualified_prefix, accumulator,
                 self_base: eval_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The `class <<` arm shared by the two member-layout walks: the expression evaluates in
        # the enclosing cref while the body's cref is the unnameable singleton class.
        def walk_singleton_member_layouts(node, qualified_prefix, accumulator, walk, self_base,
                                          singleton_cref)
          send(walk, node.expression, qualified_prefix, accumulator,
               self_base: self_base, singleton_cref: singleton_cref)
          return unless node.body

          # `self` below `class <<` is the singleton class — `self::` headers decline.
          send(walk, node.body, qualified_prefix, accumulator,
               self_base: EMPTY_PREFIX, singleton_cref: true)
        end

        # Records `qualified -> { members:, keyword_init: }` when `expr` is a `Struct.new(*Symbol [, keyword_init:
        # <bool>])` call with at least one literal-Symbol member.
        def record_struct_member_layout(accumulator, qualified_parts, expr, allow_outer_block: true)
          expr = FactoryCallResolver.resolve_meta_factory_call(expr, allow_outer_block: allow_outer_block)
          return unless expr && DeclarationWalk::Rules.struct_new_call?(expr)
          return if meta_members_open?(expr)

          members = meta_member_names(expr)
          return if members.empty?

          accumulator[qualified_parts.join("::")] = {
            members: members.freeze,
            keyword_init: struct_new_keyword_init?(expr)
          }.freeze
        end

        # True when a `Struct.new` call carries `keyword_init: true` as a literal in its trailing keyword hash. A
        # non-literal value (or its absence) reads as `false` — the conservative positional default.
        def struct_new_keyword_init?(call_node)
          args = call_node.arguments&.arguments || []
          last = args.last
          return false unless last.is_a?(Prism::KeywordHashNode)

          last.elements.any? do |assoc|
            assoc.is_a?(Prism::AssocNode) &&
              assoc.key.is_a?(Prism::SymbolNode) && assoc.key.unescaped == "keyword_init" &&
              assoc.value.is_a?(Prism::TrueNode)
          end
        end

        private_class_method :meta_member_positionals, :build_def_nestings, :verified_def_nestings,
                             :legacy_def_nestings, :walk_def_nestings, :walk_def_nesting_declaration,
                             :walk_def_nesting_meta_new?, :walk_def_nesting_eval?, :nesting_lexical_prefix,
                             :build_superclass_tables, :superclass_walk_root, :verified_superclass_tables,
                             :legacy_superclass_tables, :walk_class_superclasses, :walk_superclass_eval_call?,
                             :walk_superclass_meta_new?, :walk_superclass_declaration?, :walk_singleton_superclasses,
                             :declared_ancestor_names, :collect_mixin_names, :mixin_call?, :record_mixin_names,
                             :build_data_member_layouts, :member_layout_tables, :verified_member_layouts,
                             :legacy_data_member_layouts, :walk_data_member_layouts, :walk_data_layout_meta_new?,
                             :walk_layout_declaration, :build_struct_member_layouts, :legacy_struct_member_layouts,
                             :walk_struct_member_layouts, :walk_struct_layout_meta_new?,
                             :walk_member_layout_eval_call?, :walk_singleton_member_layouts, :struct_new_keyword_init?
      end
    end
  end
end
