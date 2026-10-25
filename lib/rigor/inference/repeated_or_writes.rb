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
    # `StatementEvaluator` types a repeating body from one entry scope too — its statement pass and every ADR-56
    # write-back pass — and marks the generic pass's sites there (issue #1336).
    #
    # The mark is per site, not per receiver, because nothing about the receiver's type can say that its slot
    # was filled: `{}` widens to untyped keys and values, a bare `Hash.new` is not widened at all, and
    # a constant, class variable, attribute reader or nested memo (`(cache[:a] ||= {})[:b] ||= e`) is no binding
    # the fold rebinds. A narrowing or a rebind of the receiver's variable leaves the mark where it is.
    #
    # A site whose receiver is fresh at every run — a hash or array literal, a `.new` call on a constant, or the
    # own slots of a local only the body binds, always to such an object — is never marked. Otherwise:
    #
    # - The generic block-return pass types the rvalue from the signature's parameter type, which covers every
    #   run's store, so it marks a site only when the site is not ISOLATED ({.isolated?}): some other store in the
    #   body may fill its slot with something else. `words.map { |w| pool[w] ||= w }` keeps its String elements.
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

      # {StraightLine.sites}: the sites of a straight-line body that an earlier store in it may have filled, with the
      # root's kind read from `scope`, the body's entry scope.
      def straight_line_sites(body, scope) = StraightLine.sites(body, scope)

      # One source slice is far cheaper than the walk, and a body that spells no `||=` holds no such site. A
      # heredoc's text lies outside its node's location, so a body that opens one is walked regardless. A slice that
      # is not valid in its encoding (an invalid byte in a comment) cannot be regex-matched, so it is walked too.
      def may_hold_or_write?(body)
        source = body.slice
        return true unless source.valid_encoding?

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

      # The index `||=` sites of a straight-line body — a method body, or a file's top level — whose slot a store that
      # comes EARLIER in the body may have filled (issue #1885). A `class` / `module` body is typed from a scope of its
      # own, which the top level's marks do not reach, so its sites are never marked; its stores are still walked, since
      # one into a constant or a global reaches a later top-level site. Whether that store ran is not something the
      # reading at the later site can see: a conditional store's slot narrowing does not survive the join with the arm
      # that skipped it, and a store in a block (`tap`, `then`) leaves none behind, so the later site's `[]` read was a
      # lone `Dynamic` again and the memoization reading answered its own rvalue —
      # `c[:k] ||= :e if cond; (c[:k] ||= :f)` typed `:f` where Ruby answers `:e` when `cond` held. Only a store
      # through the site's own variable counts ({RepeatedOrWrites.receiver_path}); an alias (`d = c`), a block
      # parameter and a helper method's store are not seen, which is the cost the memoization reading already
      # accepts. A store reaches the site's slot when it is
      #
      # - at the site's depth, with a key that may name the same slot (a literal that `eql?`s the site's, or one that is
      #   no literal; a mutator such as `merge!` or `insert` writes any slot);
      # - above it, installing anything but an empty `{}` / `[]` / `Hash.new` / `Array.new` (`c[:a] = { k: :e }` above
      #   `c[:a][:k] ||= :f`);
      # - below it, through the site's slot (`c[:a][:k] = 1` cannot run unless `c[:a]` holds an object).
      #
      # Two relations reach the slot only when the root object is not a `Hash` ({Analysis#unless_hash}): a store that
      # only removes or reorders (`delete`, `shift`, `compact!`), which on an `Array` moves an element into the slot,
      # and a literal key that differs from the site's but that an `Array` reads as the same index or an unknown `[]`
      # may normalise (`:k` and `"k"`, `1` and `1.0`, `-1` and `2`). The statement evaluator and the user-method return
      # re-walk lay the sites at the body's entry (`Scope#with_repeated_or_writes`), the same mark the repeating-block
      # passes lay, deciding the root's kind from the entry scope and the body's writes.
      module StraightLine
        # `marked` is marked whatever the root is; `unless_hash` maps a site to the root the entry scope decides on;
        # `root_writes` maps each root the body writes to `:hash` when every write stores a new `Hash`, else `:other`.
        Analysis = Data.define(:marked, :unless_hash, :root_writes)
        NOTHING = Analysis.new(marked: NO_SITES, unless_hash: {}.compare_by_identity.freeze, root_writes: {}.freeze)

        # The stores at one `[root, depth]`, or the deeper stores through one of its slots. `by_key` groups the ones
        # with a literal key by that key (`eql?`, as a `Hash` compares), and `by_tag` the same groups by
        # {.key_tag}; `wild` holds the ones with no literal key, `removers` the remove-or-reorder calls, and
        # `installers` the ones that may put a non-empty object into a slot of this object.
        Bucket = Struct.new(:by_key, :by_tag, :wild, :removers, :installers) do
          def self.fresh = new({}, Hash.new { |table, tag| table[tag] = [] }, [], [], [])

          def add_keyed(value, store)
            group = by_key[value]
            unless group
              group = by_key[value] = []
              by_tag[StraightLine.key_tag(value)] << value
            end
            group << store
          end
        end

        # The tags under which two different literal keys name different slots of any receiver.
        DISTINCT_TAGS = Set[:symbol, :string, :index].freeze

        # The main Ractor's {.analysis} memo, keyed on the body node by identity; a pool worker computes it every
        # time.
        @memo = ObjectSpace::WeakMap.new

        module_function

        def sites(body, scope)
          found = analysis(body)
          return found.marked if found.unless_hash.empty?

          found.marked + found.unless_hash.filter_map { |site, root| site unless hash_root?(root, found, scope) }
        end

        def analysis(body)
          return NOTHING unless body.is_a?(Prism::Node) && RepeatedOrWrites.may_hold_or_write?(body)
          return compute(body) unless Ractor.main?

          @memo[body] ||= compute(body)
        end

        def compute(body)
          walked = RepeatedOrWrites::Walk.new([], {}.compare_by_identity, [], Set.new, {})
          RepeatedOrWrites.walk(body, true, walked)
          return NOTHING if walked.or_writes.empty?

          Scan.new(body, walked).run
        end

        def key_tag(value)
          case value
          when Symbol then :symbol
          when String then :string
          when Integer then value.negative? ? :negative : :index
          else :float
          end
        end

        def literal_key_value(node)
          case node
          when Prism::SymbolNode then node.unescaped.to_sym
          when Prism::StringNode then node.unescaped
          when Prism::IntegerNode, Prism::FloatNode then node.value
          end
        end

        # Whether the entry scope and the body's own writes show the root is a `Hash`: a local the entry scope
        # binds (a parameter) or an instance variable by its entry type, a local only the body binds by its writes;
        # either way no write in the body may store anything else.
        def hash_root?(root, found, scope)
          writes = found.root_writes[root]
          return false if writes == :other

          kind, name = root
          case kind
          when :local then scope.locals.key?(name) ? hash_type?(scope.local(name)) : writes == :hash
          when :ivar then hash_type?(scope.ivar(name))
          else false
          end
        end

        def hash_type?(type)
          case type
          when Type::HashShape then true
          when Type::Nominal then type.class_name == "Hash"
          else false
          end
        end

        # An expression that evaluates to a new core `Hash`.
        def new_hash?(node)
          case node
          when Prism::HashNode then true
          when Prism::CallNode then node.name == :new && constant_named?(node.receiver, :Hash)
          else false
          end
        end

        # An expression that evaluates to a new, empty `Hash` or `Array`, which holds no slot a later site reads.
        def empty_fresh?(node)
          case node
          when Prism::HashNode, Prism::ArrayNode then node.elements.empty?
          when Prism::CallNode
            node.name == :new && node.arguments.nil? && node.block.nil? &&
              (constant_named?(node.receiver, :Hash) || constant_named?(node.receiver, :Array))
          else false
          end
        end

        def constant_named?(node, name)
          case node
          when Prism::ConstantReadNode then node.name == name
          when Prism::ConstantPathNode then node.parent.nil? && node.name == name
          else false
          end
        end

        # One body's stores, bucketed by object so that each site compares only against the stores that can reach
        # it: a site whose key is a literal looks up its own key's group, the stores with no literal key, and the
        # groups of the tags that do not tell its key apart.
        class Scan
          def initialize(body, walked)
            @body = body
            @walked = walked
            @buckets = Hash.new { |table, at| table[at] = Bucket.fresh }
            @deeper = Hash.new { |table, at| table[at] = Bucket.fresh }
            @parents = nil
          end

          def run
            @walked.stores.each { |store| index(store) }
            marked = []
            unless_hash = {}.compare_by_identity
            @walked.or_writes.each do |site|
              case verdict(site)
              when :marked then marked << site
              when :unless_hash then unless_hash[site] = RepeatedOrWrites.receiver_path(site.receiver, 0).first
              end
            end
            Analysis.new(marked: marked.freeze, unless_hash: unless_hash.freeze,
                         root_writes: unless_hash.empty? ? NOTHING.root_writes : root_writes)
          end

          private

          def index(store)
            return if store.path.nil?

            root, depth = store.path
            bucket = @buckets[store.path]
            node = store.node
            if node.is_a?(Prism::CallNode) && UnknownStoreWidening::VALUE_PRESERVING.include?(node.name)
              bucket.removers << store
            else
              add(bucket, StraightLine.literal_key_value(store_key(node)), store)
              bucket.installers << store unless empty_value?(node)
            end
            chain_keys(node.receiver).each_with_index do |key, at|
              break if at >= depth

              add(@deeper[[root, at]], StraightLine.literal_key_value(key), store)
            end
          end

          def add(bucket, value, store)
            value.nil? ? bucket.wild << store : bucket.add_keyed(value, store)
          end

          # The key a store writes, or nil when it may write any slot (a mutator such as `merge!` or `<<`).
          def store_key(node)
            return FreshKeys.sole_key(node) unless node.is_a?(Prism::CallNode)

            arguments = node.arguments&.arguments
            node.name == :[]= && arguments&.size == 2 ? arguments.first : nil
          end

          # Whether the store puts nothing a deeper site could read: an index write of an empty new collection.
          def empty_value?(node)
            value = case node
                    when Prism::CallNode
                      return false unless node.name == :[]=

                      node.arguments&.arguments&.last
                    when Prism::IndexTargetNode then nil
                    else node.value
                    end
            !value.nil? && StraightLine.empty_fresh?(value)
          end

          # The key of each element read between the store's root and its receiver, root first; nil for a key that is
          # no single argument.
          def chain_keys(node)
            keys = []
            loop do
              case node
              when Prism::ParenthesesNode
                statements = node.body
                break unless statements.is_a?(Prism::StatementsNode) && statements.body.size == 1

                node = statements.body.first
              when Prism::CallNode
                break unless node.name == :[] && node.receiver

                keys.unshift(FreshKeys.sole_key(node))
                node = node.receiver
              when *IndexWriteWidening::NODE_CLASSES
                keys.unshift(FreshKeys.sole_key(node))
                node = node.receiver
              else break
              end
            end
            keys
          end

          # `:marked`, `:unless_hash` or nil for one site. A literal key told apart only on a `Hash` is decided by the
          # root's kind for a site on the root alone; a deeper object's kind is not known.
          def verdict(site)
            path = RepeatedOrWrites.receiver_path(site.receiver, 0)
            return nil if path.nil?

            same = at_depth(path, site)
            return :marked if same == :marked || (same && path.last.positive?)

            above = above_depth(path, site)
            return :marked if above == :marked

            :unless_hash if same || above
          end

          # The stores at the site's depth, and the deeper ones through its object: `:marked`, `:weak` (reaching
          # unless the object is a `Hash`) or nil.
          def at_depth(path, site)
            value = StraightLine.literal_key_value(FreshKeys.sole_key(site))
            weak = false
            [@buckets.fetch(path, nil), @deeper.fetch(path, nil)].compact.each do |bucket|
              strong, loose = candidates(bucket, value)
              return :marked if reaches?(strong, site)

              weak ||= reaches?(loose, site)
            end
            weak ? :weak : nil
          end

          # The stores into a container above the site's object. A remover there moves objects between slots only
          # on an `Array`, which the root's kind decides for the root alone.
          def above_depth(path, site)
            root, depth = path
            weak = false
            (0...depth).each do |level|
              bucket = @buckets.fetch([root, level], nil) or next
              return :marked if reaches?([bucket.installers], site)
              next unless reaches?([bucket.removers], site)
              return :marked unless level.zero?

              weak = true
            end
            weak ? :weak : nil
          end

          # The store groups of `bucket` that reach a site keyed `value` on any receiver, and those that reach it
          # unless the receiver is a `Hash`.
          def candidates(bucket, value)
            return [[bucket.wild, *bucket.by_key.values], [bucket.removers]] if value.nil?

            strong = [bucket.wild]
            own = bucket.by_key[value]
            strong << own if own
            tag = StraightLine.key_tag(value)
            loose = [bucket.removers]
            bucket.by_tag.each do |other_tag, values|
              next if other_tag == tag && DISTINCT_TAGS.include?(tag)

              values.each { |other| loose << bucket.by_key[other] unless other.eql?(value) }
            end
            [strong, loose]
          end

          # Whether a store in `groups` ends before `site` starts and may have run first. A store that encloses the
          # site (`(c[:a] ||= []) << x` around `c[:a] ||= []`) stores after evaluating it, so it is not earlier.
          def reaches?(groups, site)
            start = site.location.start_offset
            groups.any? do |stores|
              stores.any? do |store|
                node = store.node
                node.location.end_offset <= start &&
                  !ExclusiveArms.exclusive?(node, site, @body, @parents ||= ExclusiveArms.parents(@body))
              end
            end
          end

          # Each variable root the body writes, `:hash` when every write stores a new `Hash`. A nested `def` is skipped;
          # a `class` / `module` body is not, so a same-named variable written there only makes the answer `:other`,
          # the side that keeps the mark.
          def root_writes
            table = {}
            collect_writes(@body, table)
            table.freeze
          end

          def collect_writes(node, table)
            return if node.is_a?(Prism::DefNode)

            kind = Forms::VARIABLE_KINDS[node.class]
            if kind && !Forms::READ_NODES.include?(node.class)
              fresh_hash = Forms::VALUE_WRITE_NODES.include?(node.class) && StraightLine.new_hash?(node.value)
              root = [kind, node.name]
              table[root] = table.fetch(root, :hash) == :hash && fresh_hash ? :hash : :other
            end
            node.rigor_each_child { |child| collect_writes(child, table) }
          end
        end

        # Whether a store and a later site sit in different arms of one `if` / `unless` (a ternary included), so that
        # the store never runs before the site in the same run of the body. That holds when no loop or lambda between
        # that conditional and the body runs both arms in turn. For a receiver that outlives the call — an instance
        # variable, a constant, a global — an earlier call of the same method can have run the other arm; the exemption
        # follows the memoization reading's existing optimism about what other calls stored. A block is not counted: one
        # its call may run more than once is the repeating-body marks' case ({.sites}), and one that runs at most once
        # (`tap`) repeats nothing. Any other relation — a `case` (whose `when` conditions run before a later arm),
        # `&&` / `||`, a `begin` and its `rescue` — counts as one where the store may have run first.
        module ExclusiveArms
          LOOP_NODES = Set[Prism::LambdaNode, Prism::WhileNode, Prism::UntilNode, Prism::ForNode].freeze

          module_function

          # The parent of every node under `body`, by identity.
          def parents(body)
            table = {}.compare_by_identity
            pending = [body]
            until pending.empty?
              node = pending.pop
              node.rigor_each_child do |child|
                table[child] = node
                pending << child
              end
            end
            table
          end

          def exclusive?(store, site, body, parents)
            chain = ancestors(store, body, parents)
            child = site
            node = parents[site]
            until node.nil? || chain.key?(node)
              child = node
              node = parents[node]
            end
            return false if node.nil? || !different_arms?(node, chain[node], child)

            ancestors(node, body, parents).each_key.none? { |above| LOOP_NODES.include?(above.class) }
          end

          # `node` and its ancestors up to `body`, each mapped to the child the walk came up through.
          def ancestors(node, body, parents)
            chain = {}.compare_by_identity
            child = nil
            until node.nil?
              chain[node] = child
              break if node.equal?(body)

              child = node
              node = parents[node]
            end
            chain
          end

          def different_arms?(node, left, right)
            arms = case node
                   when Prism::IfNode then [node.statements, node.subsequent]
                   when Prism::UnlessNode then [node.statements, node.else_clause]
                   else return false
                   end
            [left, right].all? { |arm| arms.any? { |candidate| candidate.equal?(arm) } }
          end
        end
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
