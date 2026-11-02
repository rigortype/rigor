# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "../source/node_walker"

module Rigor
  module Inference
    # Issue #2595 — the writes a def makes to its parameters that the callee floor's direct and block censuses
    # (`StatementEvaluator#own_content_parameters`) do not see, read from the def's AST alone:
    #
    # - a shape mutator the content scans do not count (`h.merge!(x)`, `h.update(x)`, `a.pop`, `h.compact!`), from
    #   `MutationWidening::SHAPE_MUTATORS`, which the caller passes in as `mutators:`;
    # - a mutation whose receiver may be the parameter or a part of it: the parameter read through any expression
    #   (`(h).merge!`, `h.itself.merge!`, `[h].first.merge!`, `(c ? {} : h).merge!`), or an alias. An alias is a
    #   local, ivar, class variable or global assigned from it (`other = h`, `x = y = h`, `a, b = h, 1`, `@x = h`,
    #   `@@x = h`, `$g = h`, `instance_variable_set(:@x, h)`), a block parameter of a call whose receiver or argument
    #   holds it (`h.tap { |x| }`, `[h].each { |x| }`, `each_with_object(h)`), or a call result on it
    #   (`v = h[:list]`) unless the call returns a new object (`fresh:`, `h.dup`, `h.merge(x)`). A literal, and a
    #   copier's result (`copiers:`, `h.values`, `h.slice(:a)`), only holds what it is built from (`t = [h]`): a
    #   write to it does not count, an element taken out does;
    # - an opaque dispatch on such a value (`send`, `instance_eval`, `method`, ...) and a mutator symbol block
    #   (`[h].each(&:clear)`).
    #
    # Issue #2336 — and a hand-off the callee floor cannot resolve, which reads the handed value as written: an
    # argument of `yield`, of `call` on any explicit receiver (a Method, a Proc, a lambda: `method(:poke).call(h)`,
    # `->(x) { }.call(h)`, `blk.(h)`), of `instance_exec` / `class_exec` / `module_exec`, or of a `send` /
    # `public_send` / `__send__` whose method name is no literal; an argument of any call inside a block that runs
    # later as a method body (`define_method(:go) { poke(h) }`, {Tables#foreign_calls}), which the hand-off walk
    # leaves out; and, when `returns:` is true, a value the def returns (its body's last expression, a `return`
    # outside a lambda) that is the parameter itself, whose caller may write it (`r = ident(h); r[:k] = 1`).
    #
    # `seeds` names the parameters and how each holds the caller's argument: a positional or keyword parameter is it
    # (`:same`); a rest or keyword-rest parameter holds the caller's arguments as elements (`:held`), so a write to the
    # rest array itself does not count and a write to an element taken out of it does.
    #
    # The walk is flow-insensitive, so an alias made anywhere counts everywhere; a local is keyed by its name and the
    # scope level it lives at, so two sibling blocks' locals of one name share a key. Both only ever count more. A
    # nested def is not entered; a block and a lambda are. A write the content scans already count on the parameter
    # read directly (a name in `handled:`, an index write on `h`) is left to them: their block channel keeps the element
    # type. `rebinds` (`{ name => end offset }`, `StatementEvaluator#parameter_rebinds`) says where the def rebinds a
    # parameter to a new object (`h = h.dup`): a node that starts after it no longer reaches the caller's argument,
    # read as `StatementEvaluator#after_rebind?` reads it.
    #
    # {Census#aliases} answers the parameters a read may be (not a part of), so a hand-off of an alias (`poke(other)`)
    # is followed as the parameter's own hand-off.
    module CalleeWriteCensus
      # `written` is the parameter names written; `alias_table` maps a key (`[local, level]`, `[ivar, :ivar]` or
      # `[cvar_or_global, :global]`) to `{ status => Set[parameter] }`: the value under the key may be the parameter
      # (status `:same`), a part of it (`:part`: `v = h[:list]`, `h.each { |k, v| }`), or hold it as an element
      # (`:held`: `arr = [h]`, which a write to `arr` does not reach).
      Census = Data.define(:written, :alias_table, :names)

      # The name tables a scan reads, which the caller owns: `mutators` (the shape and content mutators), `handled`
      # (the names the content scans count on the parameter read directly), `fresh` (calls whose result is a new
      # object), `copiers` (calls whose result is a new container of the receiver's elements) and `foreign_calls`
      # (calls whose block is a method body).
      Tables = Data.define(:mutators, :handled, :fresh, :copiers, :foreign_calls)

      NONE = [].freeze
      EMPTY = Census.new(written: NONE, alias_table: {}.freeze, names: Set.new.freeze)
      STATUSES = %i[same part held].freeze
      STATUS_INDEX = { same: 0, part: 1, held: 2 }.freeze
      # A step is how a value relates to the one it is built from, as the status it gives each of {STATUSES}.
      ID = %i[same part held].freeze
      WRAP = %i[held held held].freeze
      UNWRAP = %i[part part same].freeze
      # The mode of a mutator symbol block's record: every status counts, since the elements take the mutator.
      ANY = :any
      # Calls whose result is the receiver itself (or, for `to_a`, `to_h` and `to_s`, may be: each returns its receiver
      # on one core class and a copy on another, read as the receiver), calls whose block parameter is the receiver,
      # and calls whose result is the block's value.
      SELF_RETURNERS = %i[tap itself freeze to_a to_h to_s].to_set.freeze
      SELF_YIELDERS = %i[tap then yield_self].to_set.freeze
      BLOCK_RETURNERS = %i[then yield_self].to_set.freeze
      # Memo iterators whose memo parameter comes first (`inject(m) { |memo, e| }`); `each_with_object` puts it last.
      MEMO_FIRST = %i[inject reduce].to_set.freeze
      # Calls whose result is their memo argument's (`h.each_with_object({}) { ... }` is that `{}`).
      MEMO_RETURNERS = %i[each_with_object inject reduce].to_set.freeze
      # Iterators whose block parameter is a new array of the receiver's elements, and which return the receiver when
      # given a block and a new enumerator otherwise.
      SLICERS = %i[each_slice each_cons].to_set.freeze
      # Calls that copy (a new container of the receiver's elements) only when given an argument (`first(2)`).
      ARGUMENT_COPIERS = %i[first last min max].to_set.freeze
      # Every step {ID}, {WRAP} and {UNWRAP} compose to, as `{ outer => { inner => outer after inner } }`, closed once
      # at load: the steps are a handful of frozen tables, so the walk composes them without allocating.
      COMPOSED = begin
        steps = [ID, WRAP, UNWRAP]
        table = {}
        loop do
          size = steps.size
          steps.product(steps).each do |outer, inner|
            composed = inner.map { |status| outer[STATUS_INDEX.fetch(status)] }
            steps << composed.freeze unless steps.include?(composed)
            (table[outer] ||= {})[inner] = steps[steps.index(composed)]
          end
          break if steps.size == size
        end
        table.each_value(&:freeze).freeze
      end

      # Calls on an alias that run code the walk cannot see against it.
      OPAQUE = %i[send public_send __send__ instance_eval instance_exec instance_variable_set method
                  public_method].to_set.freeze
      # The names {Census#written} reports an anonymous rest (`*`), keyword rest (`**`) or `...` under when one is
      # handed to an opaque sink; no parameter can be named so.
      ANONYMOUS_REST = :*
      ANONYMOUS_KEYWORD_REST = :**
      ANONYMOUS_FORWARDED = [ANONYMOUS_REST, ANONYMOUS_KEYWORD_REST].freeze
      # Calls whose arguments the walk cannot follow, on an explicit receiver for `call` and on any for the rest.
      OPAQUE_ARGUMENTS = %i[call instance_exec class_exec module_exec].to_set.freeze
      # Dispatches whose target is their first argument: opaque to the walk when it is no literal name.
      SENDS = %i[send public_send __send__].to_set.freeze
      IVAR_ANY_KEY = %i[* ivar].freeze
      PARAMETER_NODES = [Prism::RequiredParameterNode, Prism::OptionalParameterNode, Prism::RestParameterNode,
                         Prism::RequiredKeywordParameterNode, Prism::OptionalKeywordParameterNode,
                         Prism::KeywordRestParameterNode].freeze
      private_constant :STATUSES, :STATUS_INDEX, :ID, :WRAP, :UNWRAP, :ANY, :SELF_RETURNERS, :SELF_YIELDERS,
                       :BLOCK_RETURNERS, :MEMO_FIRST, :MEMO_RETURNERS, :SLICERS, :ARGUMENT_COPIERS, :COMPOSED, :OPAQUE,
                       :OPAQUE_ARGUMENTS, :ANONYMOUS_FORWARDED, :SENDS, :IVAR_ANY_KEY, :PARAMETER_NODES

      module_function

      # The {Census} of `body` for the parameters `seeds` (`{ name => :same | :held }`), reading `tables` ({Tables}).
      # `returns` says whether a returned parameter counts.
      #
      # `anonymous` says the def has an anonymous rest, keyword rest or `...`, which the walk reads even with no
      # seed: handed to an opaque sink, it reports {ANONYMOUS_REST} / {ANONYMOUS_KEYWORD_REST} as written.
      def scan(body, seeds, tables:, rebinds:, returns: false, anonymous: false)
        return EMPTY if body.nil? || (seeds.empty? && !anonymous)

        walk = Walk.new(tables, returns: returns)
        walk.visit(body, 0)
        walk.note_tail(body, 0) if returns
        walk.census(seeds, rebinds)
      end

      # True when a `send` / `public_send` / `__send__` call names its target with a literal (`send(:poke, h)`,
      # `send("poke", h)`), which the callee floor resolves as a call of that name.
      def literal_send?(node)
        target = node.arguments&.arguments&.first
        target.is_a?(Prism::SymbolNode) || target.is_a?(Prism::StringNode)
      end

      # The parameter names an argument `node` at walk depth `depth` may BE (not a part of, nor a container holding):
      # through an alias in `census` (`other = h; poke(other)`), or through an expression over a parameter or alias
      # (`poke(args.first)`, `poke(h.itself)`). A read of a parameter itself answers nothing here; the caller reads it.
      def handed_aliases(census, seeds, node, depth, fresh:, copiers:)
        if (name = read_name(node))
          return NONE unless census.names.include?(name)

          return lookup(census.alias_table, read_key(node, depth), :same)
        end
        return NONE unless node.is_a?(Prism::CallNode) || node.is_a?(Prism::ParenthesesNode)

        tables = Tables.new(mutators: NONE, handled: NONE, fresh: fresh, copiers: copiers, foreign_calls: NONE)
        found = Walk.new(tables).value_sources(node, depth)
        found.nil? ? NONE : same_parameters(census, seeds, found)
      end

      # The parameters the flat `found` sources give a value as the value itself.
      def same_parameters(census, seeds, found)
        result = nil
        each_record(found, 2) do |key, step|
          STATUSES.each do |status|
            next unless apply(step, status) == :same

            parameters = lookup(census.alias_table, key, status)
            (result ||= []).concat(parameters) unless parameters.empty?
          end
          seed = seed(key, seeds)
          (result ||= []) << key.first if seed && apply(step, seed) == :same
        end
        result.nil? ? NONE : result.uniq
      end

      # The name part of {#read_key}, allocating nothing; nil for anything but a read.
      def read_name(node)
        case node
        when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode,
             Prism::GlobalVariableReadNode
          node.name
        when Prism::ItLocalVariableReadNode then :it
        end
      end

      # The key a read node stands for at walk depth `depth`, or nil.
      def read_key(node, depth)
        case node
        when Prism::LocalVariableReadNode then [node.name, depth - node.depth]
        when Prism::ItLocalVariableReadNode then [:it, depth]
        when Prism::InstanceVariableReadNode then [node.name, :ivar]
        when Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode then [node.name, :global]
        end
      end

      # The parameters `key` holds under `status`; an ivar also holds what a non-literal `instance_variable_set` stored.
      def lookup(table, key, status)
        found = table[key]&.[](status)
        if key.last == :ivar
          any = table[IVAR_ANY_KEY]&.[](status)
          found = found.nil? ? any : found | any if any
        end
        found.nil? ? NONE : found.to_a
      end

      # The status a value reached through `step` has when its source has `status`: a literal wraps it (`[h]` holds
      # `h`), a call or an element of it unwraps it (`[h].first` is `h`, `h[:list]` a part of `h`), a self-returner
      # (`h.tap`) and anything else pass it on.
      def apply(step, status) = step[STATUS_INDEX.fetch(status)]

      # How the parameter `key` reads holds the caller's argument (`seeds`), or nil when `key` is no parameter read at
      # method scope.
      def seed(key, seeds) = key.last.equal?(0) ? seeds[key.first] : nil

      # Yields each `width`-long record (at most four) of the flat `list` (nil: none) as separate arguments, allocating
      # nothing; a block taking fewer arguments ignores the rest.
      def each_record(list, width)
        return if list.nil?

        i = 0
        while i < list.size
          yield list[i], list[i + 1], list[i + 2], list[i + 3]
          i += width
        end
      end

      # True when `node` starts after the def rebinds the parameter `name` ({#scan}'s `rebinds`).
      def rebound?(rebinds, name, node)
        offset = rebinds[name]
        !offset.nil? && node.location.start_offset >= offset
      end

      # The step `outer` after `inner` ({COMPOSED}).
      def compose(outer, inner) = COMPOSED.fetch(outer).fetch(inner)

      # True when a mutation under `mode` (a step, or {ANY}) reaches a value of `status`: the value itself or a part
      # of it, not a container holding it, unless every status counts.
      def reaches?(mode, status) = mode == ANY || apply(mode, status) != :held

      # The value forms {Walk} reads a value's sources through: what a value may be built from, and how.
      module ValueSources
        private

        # `acc` (nil until the first) with each `key, step` a value may be built from at `depth` appended, flat;
        # `step` is how the value relates to the key ({CalleeWriteCensus.apply}).
        def sources(node, depth, acc, step)
          case node
          when Prism::LocalVariableReadNode, Prism::ItLocalVariableReadNode, Prism::InstanceVariableReadNode,
               Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode
            (acc ||= []).push(CalleeWriteCensus.read_key(node, depth), step)
          when Prism::ParenthesesNode, Prism::StatementsNode, Prism::OrNode, Prism::AndNode, Prism::ElseNode,
               Prism::AssocNode, Prism::SplatNode, Prism::AssocSplatNode
            node.rigor_each_child { |child| acc = sources(child, depth, acc, step) }
          when Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode
            inner = CalleeWriteCensus.compose(step, WRAP)
            node.rigor_each_child { |child| acc = sources(child, depth, acc, inner) }
          when Prism::CallNode then acc = call_sources(node, depth, acc, step)
          else acc = branch_sources(node, depth, acc, step)
          end
          acc
        end

        # The value forms that pick one of several branches, or pass on a write's value (`x = y = h`).
        def branch_sources(node, depth, acc, step)
          case node
          when Prism::IfNode then sources(node.subsequent, depth, sources(node.statements, depth, acc, step), step)
          when Prism::UnlessNode
            sources(node.else_clause, depth, sources(node.statements, depth, acc, step), step)
          when Prism::CaseNode, Prism::CaseMatchNode
            node.conditions.each { |condition| acc = sources(condition.statements, depth, acc, step) }
            sources(node.else_clause, depth, acc, step)
          when Prism::BeginNode then begin_sources(node, depth, acc, step)
          when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode,
               Prism::GlobalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode
            sources(node.value, depth, acc, step)
          else acc
          end
        end

        # A `begin` block's value: its statements, each `rescue` clause's, or its `else` clause's.
        def begin_sources(node, depth, acc, step)
          acc = sources(node.statements, depth, acc, step)
          rescue_clause = node.rescue_clause
          while rescue_clause
            acc = sources(rescue_clause.statements, depth, acc, step)
            rescue_clause = rescue_clause.subsequent
          end
          sources(node.else_clause, depth, acc, step)
        end

        def call_sources(node, depth, acc, step)
          name = node.name
          return acc if @fresh.include?(name)
          # A copier builds a new container of the receiver's elements (`h.values`, `h.slice(:a)`, `to_h { }`): a write
          # to it misses the receiver, an element taken out of it may be a part.
          return memo_sources(node, depth, acc, step) if MEMO_RETURNERS.include?(name) && node.arguments
          return sources(node.receiver, depth, acc, step) if SLICERS.include?(name) && node.block

          return sources(node.receiver, depth, acc, CalleeWriteCensus.compose(step, WRAP)) if copier?(node)
          return ivar_get_sources(node, acc, step) if name == :instance_variable_get && self_receiver?(node)

          if BLOCK_RETURNERS.include?(name) && node.block.is_a?(Prism::BlockNode)
            acc = sources(node.block.body, depth + 1, acc, step)
          end
          inner = SELF_RETURNERS.include?(name) ? step : CalleeWriteCensus.compose(step, UNWRAP)
          sources(node.receiver, depth, acc, inner)
        end

        def copier?(node)
          name = node.name
          @copiers.include?(name) || SLICERS.include?(name) || (name == :to_h && node.block) ||
            (ARGUMENT_COPIERS.include?(name) && node.arguments)
        end

        # A memo iterator's result: `each_with_object`'s is its memo argument; `inject(m)`'s is the block's last value,
        # read as the argument or an element of the receiver.
        def memo_sources(node, depth, acc, step)
          node.arguments.arguments.each { |argument| acc = sources(argument, depth, acc, step) }
          return acc if node.name == :each_with_object

          sources(node.receiver, depth, acc, CalleeWriteCensus.compose(step, UNWRAP))
        end

        def ivar_get_sources(node, acc, step)
          target = node.arguments&.arguments&.first
          (acc || []).push(target.is_a?(Prism::SymbolNode) ? [target.unescaped.to_sym, :ivar] : IVAR_ANY_KEY, step)
        end
      end
      private_constant :ValueSources

      # How {Walk} binds a block's parameters to the values of the call that yields to it.
      module BlockBindings
        private

        # A block parameter takes an element of the receiver (`[h].each { |x| }`, `h.each { |k, v| }`), the receiver
        # itself under a self-yielder (`h.tap { |x| }`), or an argument itself (`each_with_object(h) { |_, m| }`). A
        # slicer's block parameter (`each_slice`, `each_cons`) is a new array of the receiver's elements.
        def note_block(node, depth)
          params = block_parameters(node.block, depth + 1)
          return if params.empty?

          arguments = node.arguments&.arguments
          memo = memo_index(node.name, node.block, params) if arguments && !arguments.empty?
          found = sources(node.receiver, depth, nil, receiver_block_step(node.name, node.block))
          return note_memo_block(node, depth, params, memo, found) if memo

          arguments&.each { |argument| found = sources(argument, depth, found, ID) }
          edge(found, node) { params } if found
        end

        # A memo iterator with a memo argument (`each_with_object(m)`, `inject(m)`, `reduce(m)`) binds its memo
        # parameter (at `memo`) from the argument alone, and the element parameters from the receiver (`found`).
        def note_memo_block(node, depth, params, memo, found)
          elements = params.dup.tap { |list| list.delete_at(memo) }
          edge(found, node) { elements } if found && !elements.empty?
          held = nil
          node.arguments.arguments.each { |argument| held = sources(argument, depth, held, ID) }
          edge(held, node) { params[memo] } if held
        end

        # A slicer's block parameter holds a slice only when the block takes it whole (`|s|`, `it`, `_1` alone); a
        # block that destructures it (`|a, b|`, `_2`) takes the receiver's elements.
        def receiver_block_step(name, block)
          if SELF_YIELDERS.include?(name) then ID
          elsif SLICERS.include?(name) && whole_parameter?(block) then WRAP
          else UNWRAP
          end
        end

        # The index, among the `keys` a memo iterator `name`'s block binds, of its memo parameter, or nil. The memo is
        # bound only when the block takes at least two top-level positional parameters (requireds and optionals) and
        # the memo's is a plain required one (the last of `each_with_object`'s, the first of `inject`'s); `|x|`, `it`
        # or `_1` alone is the element, and a destructured memo binds nothing.
        def memo_index(name, block, keys)
          positional = top_level_parameters(block)
          return if positional.nil? || positional.size < 2

          memo = name == :each_with_object ? positional.last : (positional.first if MEMO_FIRST.include?(name))
          memo_name = parameter_name(memo)
          memo_name && keys.index { |key| key.first == memo_name }
        end

        # The name a plain parameter binds: a required parameter's, or a numbered placeholder's (`:_2`); nil otherwise.
        def parameter_name(param)
          case param
          when Symbol then param
          when Prism::RequiredParameterNode then param.name
          end
        end

        # The block's top-level positional parameters, requireds then optionals (`:_1`, `:_2` for numbered ones), or nil
        # for `it` / none.
        def top_level_parameters(block)
          params = block.parameters
          case params
          when Prism::NumberedParametersNode then (1..params.maximum).map { |i| :"_#{i}" }
          when Prism::BlockParametersNode
            inner = params.parameters
            inner.nil? ? nil : [*inner.requireds, *inner.optionals]
          end
        end

        # True when the block takes its one yielded value whole: `it`, `_1` alone, or one plain required parameter.
        def whole_parameter?(block)
          params = block.parameters
          case params
          when Prism::ItParametersNode then true
          when Prism::NumberedParametersNode then params.maximum == 1
          when Prism::BlockParametersNode
            inner = params.parameters
            !inner.nil? && inner.requireds.size == 1 && inner.requireds.first.is_a?(Prism::RequiredParameterNode) &&
              inner.optionals.empty? && inner.rest.nil? && inner.posts.empty? && inner.keywords.empty? &&
              inner.keyword_rest.nil?
          else false
          end
        end

        def block_parameters(block, depth)
          params = block.parameters
          case params
          when Prism::NumberedParametersNode then (1..params.maximum).map { |i| [:"_#{i}", depth] }
          when Prism::ItParametersNode then [[:it, depth]]
          when Prism::BlockParametersNode
            found = []
            Source::NodeWalker.each(params.parameters) do |param|
              found << [param.name, depth] if PARAMETER_NODES.any? { |klass| param.is_a?(klass) } && param.name
            end
            found
          else NONE
          end
        end
      end
      private_constant :BlockBindings

      # Issue #2336 — how {Walk} reads the values a def returns ({CalleeWriteCensus.scan}'s `returns:`).
      module Returns
        # Records what the def's value may be: the last expression of each branch of `node` (a body, a branch, a
        # `begin` clause), read as {ValueSources#sources} reads a value.
        def note_tail(node, depth)
          case node
          when nil, Prism::ReturnNode then nil
          when Prism::StatementsNode then note_tail(node.body.last, depth)
          when Prism::ParenthesesNode then note_tail(node.body, depth)
          when Prism::ElseNode then note_tail(node.statements, depth)
          when Prism::IfNode, Prism::UnlessNode
            note_tail(node.statements, depth)
            note_tail(node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause, depth)
          when Prism::CaseNode, Prism::CaseMatchNode
            node.conditions.each { |condition| note_tail(condition.statements, depth) }
            note_tail(node.else_clause, depth)
          when Prism::BeginNode then note_begin_tail(node, depth)
          else note_returned(node, depth)
          end
        end

        # A `return` outside a lambda returns from the def, when the scan counts returns ({#note_tail} ran first).
        def note_return(node, depth)
          values = node.arguments&.arguments
          note_returned(values.first, depth) if values&.size == 1 && @lambdas.zero? && @returns
        end

        def note_begin_tail(node, depth)
          note_tail(node.statements, depth)
          rescue_clause = node.rescue_clause
          while rescue_clause
            note_tail(rescue_clause.statements, depth)
            rescue_clause = rescue_clause.subsequent
          end
          note_tail(node.else_clause, depth)
        end

        # Records the variable a value the def may return reads, `key, node` flat: a read itself, through a write's
        # value (`@x = h`), either side of `||` / `&&` and a parenthesised body. A call's result is not read as the
        # parameter, even one that returns its receiver (`h.tap { }`), so the census stays exact on the spellings it
        # reads; an element taken out (`[h].first`) or a conversion (`h.to_s`) is left out too.
        def note_returned(value, depth)
          case value
          when Prism::LocalVariableReadNode, Prism::ItLocalVariableReadNode, Prism::InstanceVariableReadNode,
               Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode
            (@returned ||= []).push(CalleeWriteCensus.read_key(value, depth), value)
          when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode,
               Prism::GlobalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode
            note_returned(value.value, depth)
          when Prism::OrNode, Prism::AndNode
            note_returned(value.left, depth)
            note_returned(value.right, depth)
          when Prism::ParenthesesNode then note_tail(value.body, depth)
          end
        end

        # `written` with each parameter a returned value is itself ({#note_returned}), unless the def rebound it first.
        def returned_parameters(written, table, seeds, rebinds)
          CalleeWriteCensus.each_record(@returned, 2) do |key, node|
            parameters = table.dig(key, :same)
            written = (written || Set.new).merge(parameters) if parameters
            next unless CalleeWriteCensus.seed(key, seeds) == :same
            next if CalleeWriteCensus.rebound?(rebinds, key.first, node)

            (written ||= Set.new) << key.first
          end
          written
        end
      end
      private_constant :Returns

      # Issue #2336 — how {Walk} reads a hand-off to code it cannot see: an opaque sink's arguments, and a call inside
      # a block that is a method body.
      module OpaqueSinks
        private

        def visit_counted(child, depth, counter)
          instance_variable_set(counter, instance_variable_get(counter) + 1)
          visit(child, depth)
        ensure
          instance_variable_set(counter, instance_variable_get(counter) - 1)
        end

        # True for a call whose block runs later as a method body (`foreign_calls`: `define_method`, ...).
        def foreign_block?(node)
          node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode) && @foreign_calls.include?(node.name)
        end

        # True for a call whose arguments the walk reads as written ({CalleeWriteCensus}, issue #2336).
        def opaque_argument_call?(node)
          name = node.name
          return true if @foreign.positive?
          return !CalleeWriteCensus.literal_send?(node) if SENDS.include?(name)
          return false unless OPAQUE_ARGUMENTS.include?(name)

          # A receiverless `call` is a self-call to a def of that name, which the hand-off walk resolves; the `*_exec`
          # calls run their block whatever the receiver.
          name != :call || !self_receiver?(node)
        end

        # Records each argument of `node` (a call or a `yield`) as written, through any container: the code that
        # receives it is not seen.
        def opaque_arguments(node, depth)
          node.arguments&.arguments&.each do |argument|
            case argument
            when Prism::KeywordHashNode
              argument.elements.each do |element|
                value = element.value
                value.nil? ? anonymous_argument(ANONYMOUS_KEYWORD_REST) : opaque_argument(value, depth, node)
              end
            when Prism::SplatNode
              expression = argument.expression
              expression.nil? ? anonymous_argument(ANONYMOUS_REST) : opaque_argument(expression, depth, node)
            when Prism::ForwardingArgumentsNode then ANONYMOUS_FORWARDED.each { |rest| anonymous_argument(rest) }
            else opaque_argument(argument, depth, node)
            end
          end
        end

        # An anonymous rest (`*`), keyword rest (`**`) or `...` handed on: every argument it carries is written.
        def anonymous_argument(rest) = (@anonymous ||= Set.new) << rest

        def opaque_argument(value, depth, node)
          CalleeWriteCensus.each_record(sources(value, depth, nil, ID), 2) do |key, _step|
            (@mutations ||= []).push(key, node, true, ANY)
          end
        end
      end
      private_constant :OpaqueSinks

      # One pass over a body, collecting alias edges and mutation sites; {#census} closes them.
      class Walk
        include ValueSources
        include BlockBindings
        include Returns
        include OpaqueSinks

        def initialize(tables, returns: false)
          @mutators = tables.mutators
          @handled = tables.handled
          @fresh = tables.fresh
          @copiers = tables.copiers
          @foreign_calls = tables.foreign_calls
          @returns = returns
          @edges = nil
          @mutations = nil
          @returned = nil
          @anonymous = nil
          @foreign = 0
          @lambdas = 0
        end

        # {ValueSources#sources} of `node` at `depth`, as `node` itself: the flat `key, step` list, or nil.
        def value_sources(node, depth) = sources(node, depth, nil, ID)

        # A nested def is a scope of its own; a block and a lambda are entered one level deeper. The block of a
        # foreign-self call ({#foreign_block?}) and a lambda are counted as they are entered.
        def visit(node, depth)
          return if node.nil? || node.is_a?(Prism::DefNode)

          note(node, depth)
          foreign = foreign_block?(node)
          node.rigor_each_child do |child|
            if child.is_a?(Prism::LambdaNode) then visit_counted(child, depth + 1, :@lambdas)
            elsif foreign && child.is_a?(Prism::BlockNode) then visit_counted(child, depth + 1, :@foreign)
            else visit(child, child.is_a?(Prism::BlockNode) ? depth + 1 : depth)
            end
          end
        end

        # Every parameter in `seeds` some mutation reaches.
        def census(seeds, rebinds)
          return EMPTY if @edges.nil? && @mutations.nil? && @returned.nil? && @anonymous.nil?

          table = close(seeds, rebinds)
          written = written_parameters(table, seeds, rebinds)
          written = returned_parameters(written, table, seeds, rebinds) if @returned
          written = (written || Set.new).merge(@anonymous) if @anonymous
          return EMPTY if written.nil? && table.empty?

          Census.new(written: written.nil? ? NONE : written.to_a.freeze, alias_table: table.freeze,
                     names: alias_names(table))
        end

        private

        # The names {Census#aliases} can answer for: every key's name.
        def alias_names(table)
          names = Set.new
          table.each_key { |key| names << key.first }
          names.freeze
        end

        # The parameters the recorded mutations reach, or nil for none. A record is `key, node, counts_self, mode`.
        def written_parameters(table, seeds, rebinds)
          written = nil
          CalleeWriteCensus.each_record(@mutations, 4) do |key, node, counts_self, mode|
            written = merge_written(written, table[key], mode)
            written = merge_written(written, table[IVAR_ANY_KEY], mode) if key.last == :ivar
            status = CalleeWriteCensus.seed(key, seeds)
            next if status.nil? || !counts_self || !CalleeWriteCensus.reaches?(mode, status)

            (written ||= Set.new) << key.first unless CalleeWriteCensus.rebound?(rebinds, key.first, node)
          end
          written
        end

        def merge_written(written, by_status, mode)
          by_status&.each do |status, parameters|
            written = (written || Set.new).merge(parameters) if CalleeWriteCensus.reaches?(mode, status)
          end
          written
        end

        # `found` holds the sources flat, `key, step, key, step, ...` ({#sources}); a node that reads none records
        # nothing, so the walk allocates only where a value may carry a parameter.
        def note(node, depth)
          case node
          when Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
            found = sources(node.value, depth, nil, ID)
            edge(found, node) { [node.name, depth - node.depth] } if found
          when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
               Prism::InstanceVariableAndWriteNode
            found = sources(node.value, depth, nil, ID)
            edge(found, node) { [node.name, :ivar] } if found
          when Prism::ClassVariableWriteNode, Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
               Prism::GlobalVariableWriteNode, Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode
            found = sources(node.value, depth, nil, ID)
            edge(found, node) { [node.name, :global] } if found
          else note_other(node, depth)
          end
        end

        def note_other(node, depth)
          case node
          when Prism::MultiWriteNode
            found = sources(node.value, depth, nil, UNWRAP)
            edge(found, node) { targets(node, depth) } if found
          when Prism::ForNode
            found = sources(node.collection, depth, nil, UNWRAP)
            edge(found, node) { targets(node.index, depth) } if found
          when Prism::CallNode then note_call(node, depth)
          when Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexOperatorWriteNode, Prism::IndexTargetNode
            mutation(node.receiver, depth, node, nil)
          when Prism::YieldNode then opaque_arguments(node, depth)
          when Prism::ReturnNode then note_return(node, depth)
          end
        end

        def note_call(node, depth)
          name = node.name
          mutation(node.receiver, depth, node, name) if @mutators.include?(name) || OPAQUE.include?(name)
          opaque_arguments(node, depth) if opaque_argument_call?(node)
          note_ivar_set(node, depth) if name == :instance_variable_set && self_receiver?(node)
          case node.block
          when Prism::BlockNode then note_block(node, depth)
          when Prism::BlockArgumentNode then note_symbol_block(node, depth)
          end
        end

        def note_ivar_set(node, depth)
          arguments = node.arguments&.arguments
          return unless arguments && arguments.size >= 2

          found = sources(arguments[1], depth, nil, ID)
          return if found.nil?

          target = arguments.first
          name = target.is_a?(Prism::SymbolNode) || target.is_a?(Prism::StringNode) ? target.unescaped.to_sym : nil
          edge(found, node) { name ? [name, :ivar] : IVAR_ANY_KEY }
        end

        # `[h].each(&:clear)`: the receiver's elements, and so whatever it holds, take the mutator.
        def note_symbol_block(node, depth)
          symbol = node.block.expression
          return unless symbol.is_a?(Prism::SymbolNode) && @mutators.include?(symbol.unescaped.to_sym)

          CalleeWriteCensus.each_record(sources(node.receiver, depth, nil, ID), 2) do |key, _step|
            (@mutations ||= []).push(key, node, true, ANY)
          end
        end

        def self_receiver?(node) = node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        # Records a mutation of whatever `receiver`, any expression, may be built from ({#sources}). The parameter read
        # directly under a name the content scans count (`h << x`, `h[k] = v`; `name` nil for an index write) is theirs.
        def mutation(receiver, depth, node, name)
          found = sources(receiver, depth, nil, ID)
          return if found.nil?

          counts_self = !receiver.is_a?(Prism::LocalVariableReadNode) || !(name.nil? || @handled.include?(name))
          CalleeWriteCensus.each_record(found, 2) do |key, step|
            (@mutations ||= []).push(key, node, counts_self, step)
          end
        end

        # Records that the targets the block answers (one key, or a list of keys) take the values `found` names. The
        # edges are kept flat, `targets, found, node, ...`.
        def edge(found, node)
          targets = yield
          (@edges ||= []).push(targets, found, node) unless targets.empty?
        end

        def targets(node, depth)
          found = []
          Source::NodeWalker.each(node) do |target|
            case target
            when Prism::LocalVariableTargetNode then found << [target.name, depth - target.depth]
            when Prism::InstanceVariableTargetNode then found << [target.name, :ivar]
            when Prism::ClassVariableTargetNode, Prism::GlobalVariableTargetNode then found << [target.name, :global]
            end
          end
          found
        end

        # `{ key => { status => Set[parameter] } }` closed over the edges. A read of a parameter itself has its seed's
        # status unless the edge runs after the parameter is rebound. Each source merges straight into its targets'
        # sets, so a pass that adds nothing allocates nothing.
        def close(seeds, rebinds)
          table = {}
          return table if @edges.nil?

          changed = true
          while changed
            changed = false
            CalleeWriteCensus.each_record(@edges, 3) do |targets, found, node|
              changed = true if close_edge(table, targets, found, node, seeds, rebinds)
            end
          end
          table
        end

        # True when an edge's sources added a parameter under one of its targets.
        def close_edge(table, targets, found, node, seeds, rebinds)
          grew = false
          CalleeWriteCensus.each_record(found, 2) do |key, step|
            grew = true if flow(table, targets, step, table[key])
            grew = true if key.last == :ivar && flow(table, targets, step, table[IVAR_ANY_KEY])
            seed = CalleeWriteCensus.seed(key, seeds)
            next if seed.nil? || CalleeWriteCensus.rebound?(rebinds, key.first, node)

            status = CalleeWriteCensus.apply(step, seed)
            each_target(targets) { |target| grew = true if stored?(table, target, status, key.first) }
          end
          grew
        end

        # Adds what `by_status` (a source's entry, nil: none) holds to each target through `step`. The statuses are read
        # by name rather than by iterating the entry, which may be a target's own and grow meanwhile.
        def flow(table, targets, step, by_status)
          return false if by_status.nil?

          grew = false
          STATUSES.each do |status|
            parameters = by_status[status]
            next if parameters.nil?

            reached = CalleeWriteCensus.apply(step, status)
            each_target(targets) { |target| grew = true if stored?(table, target, reached, parameters) }
          end
          grew
        end

        # Yields each key of `targets`, one key (`[name, level]`, whose first is a Symbol) or a list of keys.
        def each_target(targets, &)
          targets.first.is_a?(Symbol) ? yield(targets) : targets.each(&)
        end

        # True when `parameters` (a set, or one name) added something under `target` and `status`.
        def stored?(table, target, status, parameters)
          set = ((table[target] ||= {})[status] ||= Set.new)
          size = set.size
          parameters.is_a?(Symbol) ? set << parameters : set.merge(parameters)
          set.size != size
        end
      end
    end
  end
end
