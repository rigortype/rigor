# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../declaration_walk/rules"
require_relative "../mutation_widening"
require_relative "mutated_element_census"

module Rigor
  module Inference
    module ScopeIndexer
      # The #540 mutation census of one file, moved out of `scope_indexer.rb` whole (ADR-116 WD9, U2).
      # {.collect_literal_receiver_mutations} records the constants and class variables a node of the file mutates
      # in place, and the elements it mutates through a read of one; every other function here is an arm or a step
      # of that walk. It asks {DeclarationWalk::Rules} for each declaration context and {MutatedElementCensus}, a
      # sibling file, for an element path, and calls nothing left in `scope_indexer.rb`, which requires this file;
      # this file does not require it back. It reads `ScopeIndexer::EMPTY_NESTING` lexically, so the file loads
      # alone but answers only once `scope_indexer.rb` has loaded: the entry is a `NameError` until then, as the
      # indexer's constants are for {NodePropagation}, which reads them the same way.
      module LiteralReceiverMutations
        module_function

        # Issue #540 — the mutation census behind the two wideners. Walks the whole tree once, tracking the
        # lexical class/module prefix, and records every node that MUTATES a constant-read or
        # class-variable-read receiver: the `Index{Or,And,Operator}Write` family, and a CallNode whose name
        # is a known in-place mutator (`MutationWidening`'s tables) or a plain attribute/index writer
        # (`name=` / `[]=`). Non-mutating reads never register, so `VERSION`-style constants keep their fold.
        #
        # @return `:constants` — a Set of candidate qualified names (each mutation
        #   contributes every lexical-resolution candidate, `A::B::C` outward to bare `C`, mirroring how the
        #   reads resolve); `:cvars` — `{class_name => Set[Symbol]}`. Issue #3243 — a mutation of an ELEMENT
        #   read off one (`S[0] << "b"`) is recorded as `[name, steps]` instead ({MutatedElementCensus.path}):
        #   `:constant_elements` — a Set of those pairs over the same candidates; `:cvar_elements` —
        #   `{class_name => Set[[Symbol, steps]]}`.
        def collect_literal_receiver_mutations(root)
          census = { constants: Set.new, cvars: Hash.new { |h, k| h[k] = Set.new },
                     constant_elements: Set.new, cvar_elements: Hash.new { |h, k| h[k] = Set.new } }
          walk_literal_receiver_mutations(root, [], census, EMPTY_NESTING)
          census
        end

        # `def_owner` names the class a `def` leaf's cvar mutations belong to when `self`
        # is rebound — see {ClassIvarIndex.walk_class_ivars}; `[]` marks a self no name covers.
        def walk_literal_receiver_mutations(node, qualified_prefix, census, nesting = EMPTY_NESTING,
                                            def_owner: nil, singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return if walk_literal_mutation_declaration?(node, qualified_prefix, census, nesting,
                                                         def_owner, singleton_cref)
          when Prism::SingletonClassNode
            # The expression evaluates in the enclosing cref; the body's cref is the
            # unnameable singleton class — the marker lifts only at a nameable header.
            return walk_singleton_literal_mutations(node, qualified_prefix, census, nesting,
                                                    def_owner, singleton_cref)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
               Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode
            return if walk_literal_mutation_meta_new?(node, qualified_prefix, census, nesting,
                                                      def_owner, singleton_cref)
          when Prism::CallNode
            return if walk_literal_mutation_meta_call?(node, qualified_prefix, census, nesting,
                                                       def_owner, singleton_cref)
            return if walk_literal_mutation_eval_call?(node, qualified_prefix, census, nesting,
                                                       def_owner, singleton_cref)

            record_literal_receiver_mutation(node, qualified_prefix, nesting, census)
          else
            record_literal_receiver_mutation(node, qualified_prefix, nesting, census)
          end

          node.rigor_each_child do |child|
            walk_literal_receiver_mutations(child, qualified_prefix, census, nesting,
                                            def_owner: def_owner, singleton_cref: singleton_cref)
          end
        end

        # The `K = Class.new { … }` arm of {#walk_literal_receiver_mutations}: the block's
        # `def`-level cvar mutations belong to the class the write names; its declarations
        # stay lexical.
        def walk_literal_mutation_meta_new?(node, qualified_prefix, census, nesting,
                                            def_owner, singleton_cref)
          split = DeclarationWalk::Rules.meta_new_block_split(node, qualified_prefix, def_owner, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_literal_receiver_mutations(part, qualified_prefix, census, nesting,
                                            def_owner: def_owner, singleton_cref: singleton_cref)
          end
          if body
            walk_literal_receiver_mutations(body, qualified_prefix, census, nesting,
                                            def_owner: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The eval-family arm of {#walk_literal_receiver_mutations}: `self::` declarations anchor
        # on the receiver (`X.class_eval { class self::D }` opens `X::D`), while bare `@@x` and
        # `X` receivers keep their lexical answers — `def_owner` rides the declaration channel
        # only.
        def walk_literal_mutation_eval_call?(node, qualified_prefix, census, nesting,
                                             def_owner, singleton_cref)
          split = DeclarationWalk::Rules.eval_block_split(node, qualified_prefix, def_owner, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_literal_receiver_mutations(part, qualified_prefix, census, nesting,
                                            def_owner: def_owner, singleton_cref: singleton_cref)
          end
          if body
            walk_literal_receiver_mutations(body, qualified_prefix, census, nesting,
                                            def_owner: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The class/module arm of {#walk_literal_receiver_mutations}: under an unnameable
        # cref a bare/`self::` header opens `#<singleton>::Name` — ownerless, and the rung
        # nothing can spell never reaches the chain; nameable headers re-anchor.
        def walk_literal_mutation_declaration?(node, qualified_prefix, census, nesting,
                                               def_owner, singleton_cref)
          ctx = DeclarationWalk::Rules.decl_body_context(node, qualified_prefix, def_owner, singleton_cref)
          return false unless ctx

          self_decl, child_prefix, child_cref = ctx
          child_nesting =
            if child_cref
              nesting
            elsif self_decl
              [self_decl.join("::"), *nesting].freeze
            else
              Source::ConstantPath.pushed_nesting(nesting, node.constant_path) || nesting
            end
          return true unless node.body

          walk_literal_receiver_mutations(node.body, child_cref ? [] : child_prefix, census,
                                          child_nesting, singleton_cref: child_cref)
          true
        end

        # The bare `Class.new { … }`-family call arm of {#walk_literal_receiver_mutations}:
        # the block's `def`-level mutations belong to an unnameable class.
        def walk_literal_mutation_meta_call?(node, qualified_prefix, census, nesting,
                                             def_owner, singleton_cref)
          return false unless DeclarationWalk::Rules.meta_new_constant_rvalue?(node) &&
                              node.block.is_a?(Prism::BlockNode)

          [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
            walk_literal_receiver_mutations(part, qualified_prefix, census, nesting,
                                            def_owner: def_owner, singleton_cref: singleton_cref)
          end
          if (body = node.block.body)
            walk_literal_receiver_mutations(body, qualified_prefix, census, nesting,
                                            def_owner: [], singleton_cref: singleton_cref)
          end
          true
        end

        def walk_singleton_literal_mutations(node, qualified_prefix, census, nesting,
                                             def_owner, singleton_cref)
          walk_literal_receiver_mutations(node.expression, qualified_prefix, census, nesting,
                                          def_owner: def_owner, singleton_cref: singleton_cref)
          return unless node.body

          # `def` below `class <<` is a singleton method — `self` is the singleton class, so
          # `self::`-anchored receivers and writes decline; the body walks ownerless.
          walk_literal_receiver_mutations(node.body, qualified_prefix, census, nesting,
                                          def_owner: [], singleton_cref: true)
        end

        # Two parameters because the two arms key on two DIFFERENT TABLES, not because the values differ:
        # `nesting.first` and `qualified_prefix.join("::")` are in fact always equal, since
        # `.declaration_prefix` and `.pushed_nesting` branch on the same `rooted?` and qualify against the same
        # parent. `qualified_prefix` is what a class variable must key on because it is the join key with
        # {ClassCvarCensus.build_class_cvar_index}, which derives its own key from the same `declaration_prefix`
        # — so the two tables agree by construction. `nesting` is what a constant name must resolve through
        # because the ladder walks every rung, not just the innermost, and a rooted header drops the outer rungs
        # from the prefix while Ruby keeps them ([#708](https://github.com/rigortype/rigor/issues/708)).
        #
        # Issue #3243 — a receiver that is an element read (`S[0] << "b"`, `@@n.dig(0, 0)[1] = 2`) mutates the element
        # the read reaches, and is recorded under the read's root with its steps, for the element widening.
        def record_literal_receiver_mutation(node, qualified_prefix, nesting, census)
          receiver = mutating_receiver_of(node)
          return if receiver.nil?

          root, steps = MutatedElementCensus.path(receiver)
          receiver = root if steps
          names = steps ? [] : census[:constants]
          case receiver
          when Prism::ConstantReadNode
            constant_mutation_candidates(receiver.name.to_s, nesting, names)
          when Prism::ConstantPathNode
            path_mutation_candidates(receiver, nesting, names)
          when Prism::ClassVariableReadNode
            unless qualified_prefix.empty?
              owner = qualified_prefix.join("::")
              steps ? census[:cvar_elements][owner] << [receiver.name, steps] : census[:cvars][owner] << receiver.name
            end
          end
          names.each { |name| census[:constant_elements] << [name, steps] } if steps
        end

        # The lexical candidates a PATH spelling reaches, for the same reason the bare arm takes them:
        # `Holder::TABLE[:k] = 1` inside `module Admin` mutates whatever `Holder::TABLE` resolves to there,
        # and since [#690](https://github.com/rigortype/rigor/issues/690) the write accumulator keys that
        # entry `Admin::Holder::TABLE`. Recording only the as-written name left the mutated constant matched
        # by nothing and its closed empty shape intact — the very fold #540 exists to retract. Over-recording
        # only widens, which is the direction this census is allowed to err in.
        #
        # A ROOTED receiver is the one spelling that reaches no lexical candidate at all, so widening them is
        # not erring in the allowed direction but discarding precision the code hands over
        # ([#703](https://github.com/rigortype/rigor/issues/703)): `::Table::ROWS[k] = 1` names the top-level
        # constant unconditionally, so the sibling `Admin::Table::ROWS` a bare spelling would also reach is
        # untouched and keeps its empty-shape fold. This is the exemption #690 established on the WRITE side
        # ({ConstantTables.constant_path_write_key}), which the two arms have to agree on: the strict render drops the
        # root marker, so the rooted and unrooted spellings are indistinguishable by name alone.
        def path_mutation_candidates(receiver, nesting, into)
          full = Source::ConstantPath.qualified_name_or_nil(receiver)
          return if full.nil?

          return into << full if Source::ConstantPath.rooted?(receiver)

          constant_mutation_candidates(full, nesting, into)
        end

        # The receiver a node mutates, or nil when the node is not a mutation.
        def mutating_receiver_of(node)
          case node
          when Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexOperatorWriteNode
            node.receiver
          when Prism::CallNode
            return nil if node.receiver.nil?
            return node.receiver if node.attribute_write?
            return node.receiver if MutationWidening::SHAPE_MUTATORS.include?(node.name)

            nil
          end
        end

        # Every lexical-resolution candidate for a bare constant name written at `nesting`, innermost first
        # — `["A::B", "A"]` + `C` yields `A::B::C`, `A::C`, `C` — so the widener matches whichever form the
        # write accumulator recorded.
        #
        # Issue #708 — this reads Ruby's `Module.nesting`, which the enclosing qualified prefix used to be a
        # faithful stand-in for. It stopped being one when a rooted header gained the power to RESET that
        # prefix: a bare `TABLE[:k] = 1` inside `class ::Rooted` in `module Outer` mutates `Outer::TABLE`, and
        # candidates built from the reset prefix never name it, so the closed shape was never widened and
        # `Outer::TABLE.empty?` folded to `true` on a table the program fills.
        def constant_mutation_candidates(base_name, nesting, into)
          nesting.each { |entry| into << "#{entry}::#{base_name}" }
          into << base_name
        end

        private_class_method :walk_literal_receiver_mutations, :walk_literal_mutation_meta_new?,
                             :walk_literal_mutation_eval_call?, :walk_literal_mutation_declaration?,
                             :walk_literal_mutation_meta_call?, :walk_singleton_literal_mutations,
                             :record_literal_receiver_mutation, :path_mutation_candidates, :mutating_receiver_of,
                             :constant_mutation_candidates
      end
    end
  end
end
