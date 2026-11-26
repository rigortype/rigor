# frozen_string_literal: true

require "prism"

require_relative "../../source/alias_names"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../declaration_walk/rules"
require_relative "certainty"

module Rigor
  module Inference
    module ScopeIndexer
      # The alias def-node pass, moved out of `scope_indexer.rb` whole (ADR-116 WD9, #3400): the post-pass over the
      # methods table's `def_nodes` that gives the new name of each `alias` and `alias_method` the `def` node its old
      # name held at the alias (#2006), and settles the new name's contest (ADR-119 WD3).
      # {.apply_alias_def_nodes} is the entry, which `ScopeIndexer.build_methods_and_def_nodes` calls once, after its
      # own walk. The other ten functions are private: the slot's writer, the walk that fills the alias map with its
      # five arms and the predicate one of them asks, and the two recorders. {AliasMap}, the map and the list of the
      # aliases it met, moved with them: only this pass builds one.
      #
      # It asks {DeclarationWalk::Rules} for each declaration context and calls one function left in
      # `scope_indexer.rb`, at two sites: `ScopeIndexer.follow_slot_writer`, the rule every writer of a def-node slot
      # settles the slot's contest by. It reads `ScopeIndexer::INSTANCE_EVAL_CALLS` lexically, as {NodePropagation}
      # reads the indexer's constants: other rows of `scope_indexer.rb` read it too.
      #
      # `scope_indexer.rb` requires this file, and this file does not require it back. It requires the file of what
      # else it names. So the file loads alone, and until `scope_indexer.rb` has loaded the entry answers only for a
      # program with no alias and no body in the block of an eval-family call, or of a class-creating call no write
      # names: an alias is a `NoMethodError` (`follow_slot_writer`), and such a block a `NameError`
      # (`INSTANCE_EVAL_CALLS`).
      module AliasDefNodes
        module_function

        # Post-pass over the `def_nodes` accumulator: for every `alias` declaration inside a class body, if the original
        # method name maps to a `Prism::DefNode`, register the new name pointing to the same node so inter-procedural
        # return-type inference works for the aliased name.
        #
        # ADR-119 WD3 — the alias is the slot's writer: the new name's slot is contested when the alias is possible
        # or the slot it copies is contested, and cleared otherwise.
        #
        # Issue #2006 — in source order. An alias copies what its old name held AT the alias, read from the walk's
        # definer history ({ScopeIndexer::MethodTables#wrote_definer}) and the copies earlier aliases made: a `def` of
        # the old name written after the alias (`alias old_x x; def x = 1`) is not what `old_x` runs, and nothing before
        # the alias copies nothing. The new name's slot then follows its last writer: a later `def` keeps the slot the
        # walk gave it, and a later `define_method` / `attr_*` leaves the copy contested, as
        # {ScopeIndexer.supersede_def_nodes} leaves a replaced `def`.
        def apply_alias_def_nodes(root, accumulator, tables)
          alias_map = collect_class_alias_map(root, [], AliasMap.new.track(tables.certainty))
          history = (tables.definer_history || {}).transform_values(&:dup)
          alias_map.copy_into(history).each { |key| settle_alias_slot(accumulator, tables, key, history[key]) }
        end

        # Writes the new name's slot from its last writer `writes.last` ({.apply_alias_def_nodes}): an alias copy or a
        # later `def` writes its `def` with its certainty (for the `def`, what the walk wrote already). A last writer
        # with no `def` this file holds — a later `define_method` / `attr_*`, or an alias that copies nothing this file
        # defines (an inherited or core method, an attr reader, a name it cannot read) — contests the slot, which keeps
        # what it holds or else the latest copy, so no sibling file's `def` fills it.
        def settle_alias_slot(accumulator, tables, (class_name, new_name), writes)
          last = writes.last
          slot = (accumulator[class_name] ||= {})
          if last[1]
            slot[new_name] = last[1]
            ScopeIndexer.follow_slot_writer(tables, :contested_def_nodes, [class_name, new_name], last[2])
          else
            copy = writes.rfind { |write| write[1] }
            slot[new_name] ||= copy[1] if copy
            ScopeIndexer.follow_slot_writer(tables, :contested_def_nodes, [class_name, new_name], false)
          end
        end

        # The `{class => {new name => old name}}` map {.collect_class_alias_map} fills, which also lists every alias it
        # met as an event `[class, new name, old name, start offset, possible?]` ({Certainty}).
        class AliasMap < Hash
          attr_reader :events

          def track(certainty)
            @certainty = certainty || Certainty::EMPTY
            @events = []
            self
          end

          # Records that `node` wrote the `[class_name, new_name]` entry, aliasing `old_name`.
          def wrote(class_name, new_name, old_name, node)
            return if @certainty.nil?

            @events << [class_name, new_name, old_name, node.location.start_offset,
                        Certainty.possible?(@certainty, node)]
          end

          # Issue #2006 — adds every alias to `history` (`{[class, name] => [[offset, def node or nil, certain,
          # (:alias)], ...]}`, ascending), in source order. An alias whose old name held a `def` at the alias copies it,
          # certain when that write and the alias are. Any other alias — an old name with no `def` of this file before
          # it (inherited, core, an attr reader, a sibling file's), or one it cannot read — adds a write with no `def`,
          # which leaves the slot contested ({AliasDefNodes.settle_alias_slot}). An alias whose new name it cannot read
          # adds one to every name of the class written before it. Returns the `[class, name]` keys it wrote.
          def copy_into(history)
            @events.sort_by { |event| event[3] }.flat_map do |class_name, new_name, old_name, at, possible|
              source = old_name && history[[class_name, old_name]]&.rfind { |write| write.first < at }
              write = if source&.[](1) then [at, source[1], source[2] && !possible, :alias].freeze
                      else [at, nil, false, :alias].freeze
                      end
              keys = new_name ? [[class_name, new_name]] : names_before(history, class_name, at)
              keys.each { |key| (history[key] ||= []).push(write).sort_by!(&:first) }
            end.uniq
          end

          private

          def names_before(history, class_name, at)
            history.filter_map { |key, writes| key if key.first == class_name && writes.first.first < at }
          end
        end

        # Builds a map `{class_name => {new_name_sym => old_name_sym}}` by walking the tree for `AliasMethodNode` nodes
        # inside class bodies. `leaf_owner` is the meta-new override: inside `K = Class.new { … }` the
        # block's aliases bind on the class the write names — it overrides `qualified_prefix`, which
        # keeps naming the enclosing lexical cref for declarations.
        def collect_class_alias_map(node, qualified_prefix, accumulator, leaf_owner = nil,
                                    singleton_cref: false, defs_singleton: false)
          return accumulator unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return collect_alias_map_declaration(node, qualified_prefix, accumulator, leaf_owner,
                                                 singleton_cref)
          when Prism::SingletonClassNode
            return collect_alias_map_singleton(node, qualified_prefix, accumulator, leaf_owner,
                                               singleton_cref)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathOrWriteNode
            return accumulator if collect_alias_map_meta_new?(node, qualified_prefix, accumulator,
                                                              leaf_owner, singleton_cref)
          when Prism::AliasMethodNode, Prism::CallNode
            return accumulator if record_alias_leaf?(node, qualified_prefix, accumulator,
                                                     leaf_owner, singleton_cref,
                                                     defs_singleton: defs_singleton)
            return accumulator if collect_alias_map_block_call?(node, qualified_prefix, accumulator,
                                                                leaf_owner, singleton_cref)
          end

          node.rigor_each_child do |child|
            collect_class_alias_map(child, qualified_prefix, accumulator, leaf_owner,
                                    singleton_cref: singleton_cref,
                                    defs_singleton: defs_singleton)
          end
          accumulator
        end

        # The alias-leaf arm of {.collect_class_alias_map}: inside a `class <<` body the alias binds
        # on the singleton — the map files nothing; a re-anchored declaration below it clears the
        # flag again, and a meta-new block's `leaf_owner` re-anchors it onto the named class.
        # Returns true when the leaf was consumed (AliasMethodNode always; a recognised
        # `alias_method` call), false when the node is an ordinary call to keep walking.
        def record_alias_leaf?(node, qualified_prefix, accumulator, leaf_owner, singleton_cref,
                               defs_singleton: false)
          rec_prefix = leaf_owner || qualified_prefix
          if node.is_a?(Prism::AliasMethodNode)
            # `defs_singleton` is the instance_eval split: the `alias` keyword binds on the
            # receiver's singleton, while `alias_method` — a call on the receiver-as-module —
            # stays instance-side and still records.
            unless defs_singleton || (singleton_cref && leaf_owner.nil?)
              record_alias_map_entry(node, rec_prefix, accumulator)
            end
            return true
          end
          return false unless node.is_a?(Prism::CallNode)

          # `alias_method :new, :old` — the CallNode twin of the `alias` keyword (#533; liquid's i18n
          # `t` alias was the corpus case). Unlike AliasMethodNode a call's children can carry further
          # class bodies (`Class.new do … end`), so the walk continues below it either way.
          names = Source::AliasNames.alias_method_call_names(node)
          if (names || unread_alias_method?(node)) && !rec_prefix.empty? && !(singleton_cref && leaf_owner.nil?)
            record_alias_call_entry(accumulator, rec_prefix.join("::"), names, node)
          end
          false
        end

        # Issue #2006 — an `alias_method` call on no receiver or `self` whose names {Source::AliasNames} cannot read
        # (`alias_method n, :to_s`, `self.alias_method :x, :y`, a splat): it still replaces a method, which
        # {AliasMap#copy_into} contests.
        def unread_alias_method?(node)
          node.name == :alias_method && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        end

        # The rebinding-block call arm of {.collect_class_alias_map}: an anonymous meta-new call
        # (`Class.new { … }` no write names) files its block's aliases nowhere, and an eval-family
        # call binds them on the receiver — a nameable receiver re-anchors the owner while a
        # receiver that names nothing, or an unnameable self below `class <<`, walks ownerless.
        def collect_alias_map_block_call?(node, qualified_prefix, accumulator, leaf_owner,
                                          singleton_cref)
          return false unless node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode)

          if DeclarationWalk::Rules.meta_new_constant_rvalue?(node)
            block_owner = []
          elsif DeclarationWalk::Rules.receiver_eval_call?(node)
            self_prefix = leaf_owner || qualified_prefix
            unnameable = DeclarationWalk::Rules.unnameable_eval_self?(false, leaf_owner, qualified_prefix,
                                                                      singleton_cref)
            block_owner = DeclarationWalk::Rules.eval_receiver_prefix(node, self_prefix, qualified_prefix,
                                                                      unnameable_self: unnameable) || []
          else
            return false
          end

          [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
            collect_class_alias_map(part, qualified_prefix, accumulator, leaf_owner,
                                    singleton_cref: singleton_cref)
          end
          if (body = node.block.body)
            collect_class_alias_map(body, qualified_prefix, accumulator, block_owner,
                                    singleton_cref: singleton_cref,
                                    defs_singleton: INSTANCE_EVAL_CALLS.include?(node.name))
          end
          true
        end

        # The meta-new arm of {.collect_class_alias_map}: the write's receiver and arguments keep
        # the enclosing context; the block's aliases bind on the class the write names, or file
        # nothing when the write is unnameable below an unnameable cref.
        def collect_alias_map_meta_new?(node, qualified_prefix, accumulator, leaf_owner,
                                        singleton_cref)
          call = DeclarationWalk::Rules.meta_new_block_call(node)
          return false unless call

          child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, leaf_owner)
          meta_ownerless = singleton_cref && !DeclarationWalk::Rules.meta_new_path_target_nameable?(node, leaf_owner)
          [call.receiver, *call.arguments&.arguments.to_a].compact.each do |part|
            collect_class_alias_map(part, qualified_prefix, accumulator, leaf_owner,
                                    singleton_cref: singleton_cref)
          end
          if (body = DeclarationWalk::Rules.meta_new_block_body(node))
            collect_class_alias_map(body, qualified_prefix, accumulator,
                                    (meta_ownerless ? nil : child_prefix) || [],
                                    singleton_cref: singleton_cref)
          end
          true
        end

        # The class/module arm of {.collect_class_alias_map}: under an unnameable cref a
        # bare/`self::` header opens `#<singleton>::Name` — the map files nothing for it;
        # a rooted or explicit-base header re-anchors at a nameable prefix.
        def collect_alias_map_declaration(node, qualified_prefix, accumulator, leaf_owner,
                                          singleton_cref)
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path, leaf_owner)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          return accumulator unless child_prefix

          child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
          if node.body
            collect_class_alias_map(node.body, child_cref ? [] : child_prefix, accumulator,
                                    singleton_cref: child_cref)
          end
          accumulator
        end

        # The `class <<` arm of {.collect_class_alias_map}: the expression evaluates in the
        # enclosing context (`class << (class D; self; end)` → `C::D`), while the body is a
        # singleton context the map files nothing for directly — a nameable declaration
        # inside still re-anchors through the flag.
        def collect_alias_map_singleton(node, qualified_prefix, accumulator, leaf_owner,
                                        singleton_cref)
          collect_class_alias_map(node.expression, qualified_prefix, accumulator, leaf_owner,
                                  singleton_cref: singleton_cref)
          if node.body
            # `self` below `class <<` is the singleton class — `self::`-anchored receivers
            # decline; a named eval receiver still re-anchors to a real class.
            collect_class_alias_map(node.body, qualified_prefix, accumulator, [],
                                    singleton_cref: true)
          end
          accumulator
        end

        def record_alias_call_entry(accumulator, class_name, names, node)
          if names.nil?
            # Issue #2006 — an unread `alias_method` maps nothing, but still replaces a method ({AliasMap#copy_into}).
            new_name = Source::AliasNames.literal_name(node.arguments&.arguments&.first)
            accumulator.wrote(class_name, new_name, nil, node) if accumulator.is_a?(AliasMap)
            return
          end

          (accumulator[class_name] ||= {})[names.first] = names.last
          accumulator.wrote(class_name, names.first, names.last, node) if accumulator.is_a?(AliasMap)
        end

        def record_alias_map_entry(alias_node, qualified_prefix, accumulator)
          return if qualified_prefix.empty?

          names = Source::AliasNames.keyword_names(alias_node)
          class_name = qualified_prefix.join("::")
          if names.nil?
            # Issue #2006 — an `alias` whose names are not plain symbols still replaces a method ({AliasMap#copy_into}).
            new_name = Source::AliasNames.symbol_name(alias_node.new_name)
            accumulator.wrote(class_name, new_name, nil, alias_node) if accumulator.is_a?(AliasMap)
            return
          end

          new_name, old_name = names
          (accumulator[class_name] ||= {})[new_name] = old_name
          accumulator.wrote(class_name, new_name, old_name, alias_node) if accumulator.is_a?(AliasMap)
        end

        private_class_method :settle_alias_slot, :collect_class_alias_map, :record_alias_leaf?, :unread_alias_method?,
                             :collect_alias_map_block_call?, :collect_alias_map_meta_new?,
                             :collect_alias_map_declaration, :collect_alias_map_singleton, :record_alias_call_entry,
                             :record_alias_map_entry
      end
    end
  end
end
