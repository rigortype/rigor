# frozen_string_literal: true

require "prism"

require_relative "../source/node_walker"
require_relative "../type"
require_relative "block_parameter_binder"
require_relative "captured_locals"
require_relative "index_write_widening"
require_relative "mutation_widening"
require_relative "unknown_store_widening"

module Rigor
  module Inference
    # The index `||=` sites of a repeating block body whose slot an EARLIER run of the body may already have
    # filled. `StatementEvaluator#index_compound_write_value` reads a `||=` whose slot types as a lone `Dynamic`
    # as the memoization idiom and answers the rvalue, on the ADR-5 reading that nothing the analyzer saw set
    # the slot. A block-return pass types every run of the body from one entry scope, so under it that reading
    # is wrong for a slot an earlier run stored into: the per-element fold's second position of
    # `cache = {}; [1, 2].find { |e| (cache[:first] ||= e) == 2 }` answered its own `2`, where Ruby keeps the
    # first iteration's `1`, folded `find` to `2` and reported `found == 2` always-truthy. The pass marks the
    # sites this module returns (`Scope#with_repeated_or_writes`), and the reading is withheld at a marked site.
    #
    # The mark is per site, not per receiver, because nothing about the receiver's type can say that its slot
    # was filled: `{}` widens to `Hash[Dynamic[top], Dynamic[top]]`, a bare `Hash.new` is not widened at all, and
    # a constant, class variable, attribute reader or nested memo (`(cache[:a] ||= {})[:b] ||= e`) is no binding
    # the fold rebinds. A narrowing or a rebind of the receiver's variable leaves the mark where it is.
    #
    # A site whose receiver is fresh at every run — a hash or array literal, a `.new` call on a constant, or the
    # own slots of a local only the body binds, always to such an object — is never marked. Otherwise:
    #
    # - The generic block-return pass types the rvalue from the signature's parameter type, which covers every
    #   run's store, so it marks a site only when the site is not ISOLATED ({.isolated?}): some other store in the
    #   body may fill its slot with something else. `words.map { |w| pool[w] ||= w }` keeps `Array[String]`.
    # - The per-element fold types each position's rvalue on its own, so it marks per position ({Marks}). The
    #   first position has no earlier one and is never marked. A later one is marked unless the site is isolated,
    #   sits at the body's own level (not in a nested block or loop), and its key differs from every earlier
    #   position's ({FreshKeys.positions}): `pool = {}; %w[a b].map { |s| pool[s] ||= s.upcase }` keeps `["A", "B"]`,
    #   and `%w[a a b].find { |s| (pool[s] ||= s) == "b" }` marks only the second position.
    module RepeatedOrWrites
      NO_SITES = [].freeze

      # The sites a pass marks at each run it types on its own. `shared` is marked at every run (the generic pass);
      # `positional[i]` at the per-element fold's position `i` only. {#at} with a nil position — a caller that
      # does not type one position — answers every site.
      Marks = Data.define(:shared, :positional) do
        def at(position)
          return shared if positional.empty?
          return positional.flatten.uniq if position.nil?

          positional.fetch(position, NO_SITES)
        end

        def empty? = shared.empty? && positional.all?(&:empty?)
      end

      NO_MARKS = Marks.new(shared: NO_SITES, positional: NO_SITES)

      # A store in the body and the object it stores into, as `[root, depth]`: the variable the receiver
      # evaluates from (`[:ivar, :@cache]`) and how many element reads lie between the two (`@cache[k][j] = v`
      # stores into depth 1). `path` is nil for an object the store cannot name. `installs_shared` is whether it
      # can put an object an earlier run may have filled into a slot — anything but a fresh object, and nothing
      # for a store that only removes or reorders.
      Store = Data.define(:node, :path, :installs_shared)

      # What the body holds: the `||=` sites to consider, the ones at the body's own level, how many stores that
      # may reach an object an earlier run saw there are (those sites included) and how many reach each path,
      # whether some store's object is unknown, the paths a store may put a shared object into, and every local
      # name the body writes.
      Scan = Data.define(:or_writes, :top_level, :store_count, :path_counts, :unattributable, :installs,
                         :written_locals)

      # The walk's accumulators. `writes` maps each variable the body writes, as `[kind, name]`, to whether every
      # write stores a fresh object into it.
      Walk = Struct.new(:or_writes, :top_level, :stores, :written_locals, :writes)

      # The node forms and source patterns the scan recognises.
      module Forms
        STORE_NODES = IndexWriteWidening::CONTENT_WRITE_NODE_CLASSES
        INDEX_WRITE_NODES = IndexWriteWidening::NODE_CLASSES

        # A call that can store through any method name, so into any slot of its receiver.
        DYNAMIC_SEND = Set[:send, :public_send, :__send__].freeze

        # A call that hands out a method as an object, which a store can then be called through.
        METHOD_HANDLES = Set[:method, :public_method].freeze

        # A heredoc opener: its text lies outside its node's location, so a `||=` in it escapes the source slice.
        HEREDOC_OPENER = /<<[~-]?["'`]?[A-Za-z_]/

        # The nodes whose children run more than once for each run of the body that contains them.
        REPEATING_NODES = Set[
          Prism::BlockNode, Prism::LambdaNode, Prism::WhileNode, Prism::UntilNode, Prism::ForNode
        ].freeze

        # Every variable read and write form, with the kind of variable it names.
        VARIABLE_KINDS = {
          local: [Prism::LocalVariableReadNode, *CapturedLocals::LOCAL_WRITE_NODES],
          ivar: [
            Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
            Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableTargetNode
          ],
          cvar: [
            Prism::ClassVariableReadNode, Prism::ClassVariableWriteNode, Prism::ClassVariableOperatorWriteNode,
            Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode, Prism::ClassVariableTargetNode
          ],
          gvar: [
            Prism::GlobalVariableReadNode, Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode,
            Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode, Prism::GlobalVariableTargetNode
          ],
          const: [
            Prism::ConstantReadNode, Prism::ConstantWriteNode, Prism::ConstantOperatorWriteNode,
            Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantTargetNode
          ]
        }.flat_map { |kind, classes| classes.map { |node_class| [node_class, kind] } }.to_h.freeze

        READ_NODES = Set[
          Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode,
          Prism::GlobalVariableReadNode, Prism::ConstantReadNode
        ].freeze

        # The writes that bind their value as it is: a plain write, and an `||=` (which keeps an object already set).
        VALUE_WRITE_NODES = Set[
          Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode,
          Prism::GlobalVariableWriteNode, Prism::ConstantWriteNode,
          Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode, Prism::ClassVariableOrWriteNode,
          Prism::GlobalVariableOrWriteNode, Prism::ConstantOrWriteNode
        ].freeze
      end
      private_constant :Forms

      module_function

      # @param block — the repeating block.
      # @param stores — {CapturedLocals.content_mutations} of the block (with `non_locals: true`): the captured
      #   variables its body mutates in place, each with its sites; its callee stores count as stores here.
      # @param scope — the call-site scope, in which a per-element fold's positions bind their parameters.
      # @param element_types — the per-element fold's position types, one per position; nil for the generic
      #   block-return pass.
      # @return the {Marks} to lay, {NO_MARKS} for the overwhelmingly common body with no such site.
      def sites(block, stores, scope, element_types: nil)
        body = block.body
        return NO_MARKS unless body && may_hold_or_write?(body)

        found = scan(block, stores, scope)
        return NO_MARKS if found.or_writes.empty?
        return generic_marks(found) if element_types.nil?

        positional_marks(block, found, stores, scope, element_types)
      end

      # One source slice is far cheaper than the walk, and a body that spells no `||=` holds no such site. A
      # heredoc's text lies outside its node's location, so a body that opens one is walked regardless.
      def may_hold_or_write?(body)
        source = body.slice
        source.include?("||=") || source.match?(Forms::HEREDOC_OPENER)
      end

      def generic_marks(found)
        Marks.new(shared: found.or_writes.reject { |node| isolated?(node, found) }, positional: NO_SITES)
      end

      def positional_marks(block, found, stores, scope, element_types)
        positional = Array.new(element_types.size) { [] }
        parameters = nil
        found.or_writes.each do |node|
          fresh = exempt_candidate?(node, found) &&
                  FreshKeys.positions(block, node, found.written_locals, stores, scope, element_types,
                                      parameters ||= CapturedLocals.introduced_locals(block))
          (1...element_types.size).each { |index| positional[index] << node unless fresh && fresh[index] }
        end
        Marks.new(shared: NO_SITES, positional: positional)
      end

      def exempt_candidate?(node, found) = found.top_level.key?(node) && isolated?(node, found)

      # Walks the body, then settles each store's object ({.settle}), and drops a site on a body-local fresh at
      # every run ({.fresh_roots}), whose own slots no earlier run saw.
      def scan(block, stores, scope)
        walked = Walk.new([], {}.compare_by_identity, [], Set.new, {})
        walk(block.body, true, walked)
        fresh = fresh_roots(block, walked.writes, scope)
        settled = (walked.stores + callee_stores(stores)).filter_map do |store|
          settle(store, walked.writes, fresh, scope)
        end
        or_writes = walked.or_writes.reject { |node| on_fresh_slot?(receiver_path(node.receiver, 0), fresh) }
        summary(walked, or_writes, settled)
      end

      def summary(walked, or_writes, settled)
        Scan.new(or_writes: or_writes, top_level: walked.top_level, store_count: settled.size,
                 path_counts: settled.map(&:path).tally, unattributable: settled.any? { |store| store.path.nil? },
                 installs: settled.select(&:installs_shared).map(&:path), written_locals: walked.written_locals)
      end

      def on_fresh_slot?(path, fresh) = !path.nil? && path.last.zero? && fresh.include?(path.first)

      # The locals the body alone binds — not captured, not a block parameter or block-local — whose every write
      # stores a fresh object.
      def fresh_roots(block, writes, scope)
        introduced = nil
        writes.each_with_object(Set.new) do |((kind, name), all_fresh), roots|
          next unless all_fresh && kind == :local && !scope.locals.key?(name)

          introduced ||= CapturedLocals.introduced_locals(block)
          roots << [kind, name] unless introduced.include?(name)
        end
      end

      # The store as the isolation test reads it; nil for one that reaches nothing an earlier run saw. A store is
      # made unattributable when its variable may name some other object: one the body binds from anything but a
      # fresh object (`other = pool`), or a local that is neither captured nor written by the body — a block
      # parameter, `it`, `_1` — which holds whatever it is handed. A body-local fresh at every run holds a new
      # object, so a store into its own slots is dropped; but that object may hold an old one (`box = [pool]`), so
      # a store deeper in is unattributable.
      def settle(store, writes, fresh, scope)
        root = store.path&.first
        return store if root.nil?

        if writes.key?(root)
          return nil if on_fresh_slot?(store.path, fresh)
          return store if writes[root] && !fresh.include?(root)
        elsif root.first != :local || scope.locals.key?(root.last)
          return store
        end
        Store.new(node: store.node, path: nil, installs_shared: true)
      end

      def walk(node, top_level, found)
        return unless node.is_a?(Prism::Node)
        return if node.is_a?(Prism::DefNode)

        record_write(node, found)
        record_store(node, top_level, found)
        return if node.is_a?(Prism::DefinedNode)

        nested_level = top_level && !Forms::REPEATING_NODES.include?(node.class)
        node.rigor_each_child { |child| walk(child, nested_level, found) }
      end

      def record_write(node, found)
        kind = Forms::VARIABLE_KINDS[node.class]
        return if kind.nil? || Forms::READ_NODES.include?(node.class)

        found.written_locals << node.name if kind == :local
        root = [kind, node.name]
        fresh = Forms::VALUE_WRITE_NODES.include?(node.class) && fresh_object?(node.value)
        found.writes[root] = found.writes.fetch(root, true) && fresh
      end

      def record_store(node, top_level, found)
        if dynamic_store?(node)
          found.stores << Store.new(node: node, path: nil, installs_shared: true)
          return
        end
        return unless store_node?(node)
        return if fresh_object?(node.receiver)

        found.stores << Store.new(node: node, path: store_path(node), installs_shared: installs_shared?(node))
        return unless node.is_a?(Prism::IndexOrWriteNode)

        found.or_writes << node
        found.top_level[node] = true if top_level
      end

      def store_node?(node)
        return true if Forms::STORE_NODES.include?(node.class)

        node.is_a?(Prism::CallNode) && store_method?(node.name)
      end

      def store_method?(name) = name == :[]= || MutationWidening::SHAPE_MUTATORS.include?(name)

      # A call that can store through a method it does not name — `send` and its kin — or that hands out a store
      # method to be called later (`pool.method(:[]=)`).
      def dynamic_store?(node)
        return false unless node.is_a?(Prism::CallNode)
        return true if Forms::DYNAMIC_SEND.include?(node.name)
        return false unless Forms::METHOD_HANDLES.include?(node.name)

        name = node.arguments&.arguments&.first
        name.is_a?(Prism::SymbolNode) && store_method?(name.unescaped.to_sym)
      end

      # Whether the store `node` can put an object an earlier run may have filled into a slot: an index write of
      # anything but a fresh object, a mutator handed one, or any other store form; not a mutator that only
      # removes or reorders.
      def installs_shared?(node)
        case node
        when Prism::IndexOrWriteNode, Prism::IndexAndWriteNode then !fresh_object?(node.value)
        when Prism::CallNode
          return false if UnknownStoreWidening::VALUE_PRESERVING.include?(node.name)

          arguments = node.arguments&.arguments || NO_SITES
          stored = node.name == :[]= ? arguments.last(1) : arguments
          stored.any? { |argument| !fresh_object?(argument) }
        else true
        end
      end

      # A call with no receiver stores into `self`.
      def store_path(node)
        return [[:self], 0] if node.receiver.nil?

        receiver_path(node.receiver, 0)
      end

      # `[root, depth]` for the object `node` evaluates to, or nil when no variable roots it.
      def receiver_path(node, depth)
        case node
        when Prism::ParenthesesNode then parenthesized_path(node, depth)
        when Prism::SelfNode then [[:self], depth]
        when Prism::ItLocalVariableReadNode then [%i[local it], depth]
        when Prism::CallNode then element_read_path(node, depth)
        when *Forms::INDEX_WRITE_NODES then receiver_path(node.receiver, depth + 1)
        else variable_path(node, depth)
        end
      end

      def parenthesized_path(node, depth)
        statements = node.body
        return nil unless statements.is_a?(Prism::StatementsNode) && statements.body.size == 1

        receiver_path(statements.body.first, depth)
      end

      def element_read_path(node, depth)
        return nil unless node.name == :[] && node.receiver && !node.safe_navigation?

        receiver_path(node.receiver, depth + 1)
      end

      def variable_path(node, depth)
        kind = Forms::VARIABLE_KINDS[node.class]
        kind && [[kind, node.name], depth]
      end

      # {CapturedLocals.content_mutations}'s callee stores — a self-call passing a captured local to a parameter
      # its callee mutates — as stores into that local.
      def callee_stores(stores)
        stores.flat_map do |name, sites|
          sites.grep(UnknownStoreWidening::CalleeStore).map do |site|
            Store.new(node: site.call, path: [[:local, name.to_sym], 0], installs_shared: true)
          end
        end
      end

      # An expression that evaluates to a new object at every run: a hash or array literal, or `.new` called on a
      # constant.
      def fresh_object?(node)
        case node
        when Prism::HashNode, Prism::ArrayNode then true
        when Prism::CallNode
          node.name == :new &&
            (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode))
        else false
        end
      end

      # True when no other store in the body can fill `node`'s slot: no other store reaches the object `node` stores
      # into (the same variable, at the same element depth), none can put a shared object into a container above it
      # on the way (`pool[:a] = shared` above `pool[:a][s] ||= s`), and every store names the object it reaches
      # ({.settle}), the site's own included. A site whose receiver no variable roots is isolated only as the
      # body's sole store.
      def isolated?(node, found)
        path = receiver_path(node.receiver, 0)
        return found.store_count == 1 if path.nil?
        return false if found.unattributable || found.path_counts[path] != 1

        root, depth = path
        found.installs.none? { |(other_root, other_depth)| other_root == root && other_depth < depth }
      end

      # Whether an index `||=` site's key differs, position by position, from every earlier position's key under
      # the per-element fold.
      module FreshKeys
        # The nodes a key expression may not contain; see {.fixed_key?}.
        KEY_UNFIXED_NODES = Set[
          Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode,
          Prism::BlockNode, Prism::LambdaNode, *CapturedLocals::LOCAL_WRITE_NODES, *CapturedLocals::NON_LOCAL_WRITE_NODES
        ].freeze

        HASH_KEY_CLASSES = [Symbol, String, Integer].freeze
        private_constant :KEY_UNFIXED_NODES, :HASH_KEY_CLASSES

        module_function

        # For each position, whether `node`'s key there is provably a value no earlier position's key equals; nil
        # when the key cannot be typed position by position. The key must be a single index argument that reads no
        # variable but ones the body never changes ({.fixed_key?}), so typing it under each position's parameter
        # binding is typing what the position evaluates. The keys up to a position must be `Constant`s its receiver
        # tells apart ({.distinguishable?}), and its own must equal none before it. A key that fails to type is not
        # shown fresh anywhere, so the site stays marked, the wider answer.
        def positions(block, node, written_locals, stores, scope, element_types, parameters)
          key = sole_key(node)
          return nil if key.nil? || !fixed_key?(key, parameters, written_locals, stores)

          typed = element_types.map do |element_type|
            position = BlockParameterBinder.new(expected_param_types: [element_type]).bind_onto(block, scope)
            [position.type_of(key), receiver_kind(position.type_of(node.receiver))]
          end
          fresh_by_position(typed)
        rescue StandardError
          nil
        end

        def fresh_by_position(typed)
          values = []
          typed.each_with_index.map do |(key_type, receiver_kind), index|
            return typed.map { false } unless key_type.is_a?(Type::Constant)

            value = key_type.value
            unseen = values.none? { |earlier| earlier.eql?(value) }
            values << value
            index.zero? || (unseen && distinguishable?(values, receiver_kind))
          end
        end

        # A core `Hash` tells apart any two `Symbol`, `String` or `Integer` keys `eql?` does, and a core `Array` any two
        # non-negative indices. Any other receiver's `[]` may normalise a key (`with_indifferent_access`, a
        # case-insensitive hash), so only non-negative `Integer`s, or keys all of one class, `Symbol` or `String`, pass.
        def distinguishable?(values, receiver_kind)
          case receiver_kind
          when :hash then values.all? { |value| HASH_KEY_CLASSES.any? { |key_class| value.is_a?(key_class) } }
          when :array then values.all? { |value| value.is_a?(Integer) && !value.negative? }
          else
            values.all? { |value| value.is_a?(Integer) && !value.negative? } ||
              values.all?(Symbol) || values.all?(String)
          end
        end

        def receiver_kind(type)
          case type
          when Type::HashShape then :hash
          when Type::Tuple then :array
          when Type::Nominal then { "Hash" => :hash, "Array" => :array }[type.class_name]
          end
        end

        def sole_key(node)
          arguments = node.arguments&.arguments
          return nil unless arguments&.size == 1 && node.block.nil?

          key = arguments.first
          key.is_a?(Prism::SplatNode) || key.is_a?(Prism::KeywordHashNode) ? nil : key
        end

        # True when `key` reads no variable the body can change between positions: every local it reads is one of
        # the block's `parameters` or a captured local, which the body neither writes nor mutates in place, and it
        # contains no instance-, class- or global-variable read, no write, and no block or lambda.
        def fixed_key?(key, parameters, written_locals, stores)
          Source::NodeWalker.each(key) do |node|
            return false if KEY_UNFIXED_NODES.include?(node.class)
            next unless node.is_a?(Prism::LocalVariableReadNode)
            return false if written_locals.include?(node.name)
            return false unless node.depth.zero? ? parameters.include?(node.name) : !stores.key?(node.name)
          end
          true
        end
      end
    end
  end
end
