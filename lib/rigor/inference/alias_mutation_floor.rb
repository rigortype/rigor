# frozen_string_literal: true

require "prism"

require_relative "../run_scoped_slots"
require_relative "../source/node_children"
require_relative "closure_escape_analyzer"
require_relative "element_read_widening"
require_relative "mutation_widening"
require_relative "receiver_alias"
require_relative "remover_holder_scan"
require_relative "set_mutation"
require_relative "string_mutation"
require_relative "unknown_store_widening"
require_relative "alias_mutation_floor/foreign_locals"
require_relative "alias_mutation_floor/site_collector"
require_relative "alias_mutation_floor/reach"

module Rigor
  module Inference
    # Issue #2335 — a local's literal shape describes its object, and a mutation through another path to that object
    # makes it stale: `y = x; y << "s"`, `a.each { |x| x << "s" }` on an Array holding `inner`, `@a = a; @a << "s"`,
    # `h[:k] = a; h[:k] << "s"`, `Hash.new(a)[:k] << "s"`, `[acc].each { |a| poke(a) }`. The named-binding widening
    # ({MutationWidening.widen_after_call}) and the callee floor only rebind the binding a receiver or argument names,
    # so every other local holding the object kept its literal and a later read reported on correct code.
    #
    # One scan per frame body, in {RemoverHolderScan}'s walk ({SiteCollector}), answers:
    #
    # - the locals handed whole to another holder: an element of a container literal, an argument of a call that may
    #   keep it, an ivar, global, index or attribute write's value, a capture by a closure that may run later, a
    #   reflective receiver, a local bound to an ivar, global or class variable (`a = @q`); every local under
    #   `binding` / `eval`. A value counts only where it may evaluate to the local itself ({.each_may_be}: the local,
    #   a selection of it, a call that answers its receiver), so `n = a.size`, `b = a.dup` and `[a.first]` hand
    #   nothing on whole;
    # - the locals one of whose elements is handed on (`[a.first]`), and the links between locals: a copy (`b = a`)
    #   and an element read (`x = a[i]`);
    # - the *foreign* locals, whose object may have come from elsewhere ({ForeignLocals}).
    #
    # A local is *aliased* at a call once a site that hands it on may have run before the call's message (a site
    # earlier in the body, or one inside a loop or block that also holds the call; a capture by a closure that may run
    # later counts everywhere, and a call inside such a closure sees every site), or it is linked to such a local. A
    # local reached only through an element link is a *part*, floored only when its binding can hold a mutable
    # element ({.mutable_parts?}).
    #
    # A mutating call whose receiver may be another local's object ({.targets}: the locals linked to the receiver, and
    # the aliased ones when the receiver may hold any object) gives each local it may reach the
    # unknown store {UnknownStoreWidening.widen_store} gives a site whose stored values nothing typed: the same
    # widening the named path applies, fed `Dynamic[top]` arguments, with its gradual arm. A callee that writes such
    # an argument, and a call on one to a method that mutates its instance variables, floor them the same way. The
    # bindings the receiver itself names are left to the named path, so its precise answer stands.
    #
    # A body where no local is handed on, and a receiver only ever written a new object that is not aliased, change
    # nothing.
    module AliasMutationFloor
      # `held` maps each local handed to another holder to the least key of those sites ({.handed_by}), or is {ALL};
      # `held_part` does the same for a local an element of which was handed on (`[a.first]`); `links` lists
      # `[child, parent, key, levels]` for each write that binds a local to another local's object (`b = a`, 0 levels)
      # or to an element of it (`x = a[i]`, 1; `x = a[i][j]`, 2; `c = [x]` links `x` as `c`'s element). `deferred`
      # lists the `[start, end)` ranges of the closures that may run later. `memo` and `named_memo` keep each call's and
      # each read's targets for the run: a loop or block body is evaluated more than once.
      Facts = Data.define(:held, :held_part, :links, :foreign, :entry, :deferred, :memo, :named_memo)
      # Depths ({.reach}): the mutated object is the local's object itself, or one of its elements.
      FULL = 0
      PART = 1
      NO_KEYS = {}.freeze
      NO_LINKS = [].freeze
      # Calls whose result is their receiver (or, for `to_a` / `to_h` / `to_s`, may be on one core class), as
      # {CalleeWriteCensus} reads them.
      SELF_RETURNERS = %i[tap itself freeze to_a to_h to_s].to_set.freeze

      ALL = :all
      NUMBERED_PARAMETER = /\A_[1-9]\z/
      SEND_NAMES = %i[send public_send __send__].to_set.freeze
      ELEMENT_READS = %i[[] first last fetch dig].to_set.freeze
      FACTS_CACHE_KEY = RunScopedSlots.register(:__rigor_alias_mutation_floor_facts)
      IVAR_CACHE_KEY = RunScopedSlots.register(:__rigor_alias_mutation_floor_ivar_mutators)
      FLOOR_CACHE_KEY = RunScopedSlots.register(:__rigor_alias_mutation_floor_callee_floors)
      STORE_CACHE_KEY = RunScopedSlots.register(:__rigor_alias_mutation_floor_unknown_stores)
      private_constant :FULL, :PART, :NO_KEYS, :NO_LINKS, :SELF_RETURNERS, :ALL, :NUMBERED_PARAMETER,
                       :SEND_NAMES, :ELEMENT_READS, :FACTS_CACHE_KEY, :IVAR_CACHE_KEY, :FLOOR_CACHE_KEY,
                       :STORE_CACHE_KEY

      module_function

      # `scope` after `call_node`, a shape mutator ({.candidate?}), ran on a receiver that may be another local's
      # object. The block answers the locals the receiver itself names, whose own widening (the named path's)
      # stands; it runs only once the call has targets.
      def floor_after_call(call_node, scope)
        return scope unless local_besides?(scope, nil) { |type| UnknownStoreWidening.callee_floorable?(type) }

        facts = facts_for(scope)
        return scope if facts.nil?

        targets = call_targets(facts, call_node) { receiver_targets(call_node.receiver, facts, call_node) }
        return scope if targets.empty?

        floor_targets(scope, targets, yield) { |type| unknown_store(call_node, type) }
      end

      # Whether `call_node` is a shape mutator on an explicit receiver, the only call {.floor_after_call} floors after.
      def candidate?(call_node)
        !call_node.receiver.nil? && MutationWidening::SHAPE_MUTATORS.include?(call_node.name)
      end

      # `scope` after `call_node` wrote the object the local `read` reads (a callee that writes its argument or mutates
      # the ivars of an object holding it): every local that may be that object and holds a literal shape
      # ({.literal_shape?}) takes one unknown store ({UnknownStoreWidening.callee_block_floor}). A method parameter the
      # body never rebinds floors nothing here: the callee census reads every opaque hand-off as a write, and flooring
      # each local a parameter was copied into at every such call cost precision across the corpus for no finding (a
      # known limit of #2335).
      def floor_after_written_local(scope, read, call_node)
        name = read.name
        return scope unless local_besides?(scope, name) { |type| literal_shape?(type) }

        facts = facts_for(scope)
        return scope if facts.nil?
        return scope if facts.entry.include?(name)

        targets = read_targets(facts, read) { targets(name, facts, aliased_at(facts, call_node), call_node) }
        return scope if targets.empty?

        floor_targets(scope, targets, name) { |type| callee_floor(type) }
      end

      # `type` after `call_node`'s unknown store ({UnknownStoreWidening.widen_store}), memoised per call site for the
      # run as {.callee_floor} is.
      def unknown_store(call_node, type)
        table = (Thread.current[STORE_CACHE_KEY] ||= {}.compare_by_identity)
        per_call = (table[call_node] ||= {})
        per_call.fetch(type) do
          method_name, arg_types = UnknownStoreWidening.unknown_store(call_node)
          per_call[type] = removed_keys_shape(type, method_name) ||
                           UnknownStoreWidening.widen_store(type, method_name, arg_types)
        end
      end

      # A `HashShape` under a remover (`delete`, `clear`, `reject!`, ...) through another holder: the same shape with
      # every key optional. Nothing is stored, so every value stands, and a read of a key the remover may have taken
      # still answers its `nil` (`g = h; g.delete(k); h[k].upcase` raises in Ruby), which the nominal `Hash` the unknown
      # store widens to would not. Nil for anything else.
      def removed_keys_shape(type, method_name)
        return nil unless type.is_a?(Type::HashShape) && UnknownStoreWidening::VALUE_PRESERVING.include?(method_name)

        Type::HashShape.new(type.pairs, required_keys: [], optional_keys: type.pairs.keys,
                                        read_only_keys: type.read_only_keys, extra_keys: type.extra_keys)
      end

      # {UnknownStoreWidening.callee_block_floor} of a literal shape, nil for anything else, memoised for the run: the
      # same shape is floored again on each pass over a loop or block body and by each callee channel.
      def callee_floor(type)
        return nil unless literal_shape?(type)

        table = (Thread.current[FLOOR_CACHE_KEY] ||= {})
        table.fetch(type) { table[type] = UnknownStoreWidening.callee_block_floor(type) }
      end

      # Whether {.floor_after_written_local} may floor anything for the local `read` reads at `call_node`: a target
      # bound to a literal shape.
      def reaches_other_locals?(scope, read, call_node)
        name = read.name
        return false unless local_besides?(scope, name) { |type| literal_shape?(type) }

        facts = facts_for(scope)
        return false if facts.nil? || facts.entry.include?(name)

        targets = read_targets(facts, read) { targets(name, facts, aliased_at(facts, call_node), call_node) }
        return local_besides?(scope, name) { |type| literal_shape?(type) } if targets.equal?(ALL)

        targets.any? do |target, kind|
          type = scope.local(target)
          target != name && literal_shape?(type) && (kind == FULL || mutable_parts?(type))
        end
      end

      # Whether a call that may mutate a holder's object through `self` ({.floor_after_holder_call}) reaches an aliased
      # local holding a literal shape.
      def holder_call_reaches?(scope, call_node)
        return false unless local_besides?(scope, nil) { |type| literal_shape?(type) }

        facts = facts_for(scope)
        return false if facts.nil?

        targets = holder_targets(facts, call_node)
        return true if targets.equal?(ALL)

        targets.any? do |target, kind|
          type = scope.local(target)
          literal_shape?(type) && (kind == FULL || mutable_parts?(type))
        end
      end

      # `scope` after a call on `self` whose method mutates one of its ivars: every aliased local holding a literal
      # shape takes one unknown store, as {.floor_after_written_local} gives it.
      def floor_after_holder_call(scope, call_node)
        facts = facts_for(scope)
        return scope if facts.nil?

        floor_targets(scope, holder_targets(facts, call_node), nil) { |type| callee_floor(type) }
      end

      def holder_targets(facts, call_node)
        call_targets(facts, call_node) { targets(nil, facts, aliased_at(facts, call_node), call_node) }
      end

      # A literal shape a store can make stale: a `Tuple`, a `HashShape`, a literal String or Set, or an empty-witness
      # refinement, alone or in a union. The callee paths floor only these: a nominal `Array[String]` is a claim the
      # named path's unknown store leaves as it is too.
      def literal_shape?(type)
        case type
        when Type::Tuple, Type::HashShape then true
        when Type::Constant then StringMutation.constant?(type) || SetMutation.constant?(type)
        when Type::Difference then type.removes_empty_witness?
        when Type::Union then type.members.any? { |member| literal_shape?(member) }
        else false
        end
      end

      # Whether the body of `def_node` runs a shape mutator on one of its own instance variables or an element of one
      # (`@items << v`, `@h[k] = v`, `@rows[0] << v`): a call to it on an object that holds another local's object
      # (`box = Box.new(a)`, whose `initialize` keeps `@items = a`) may mutate that object. A nested def is not entered.
      def mutates_ivar?(def_node)
        return false if def_node.nil?

        table = (Thread.current[IVAR_CACHE_KEY] ||= ObjectSpace::WeakKeyMap.new)
        cached = table[def_node]
        return cached unless cached.nil?

        table[def_node] = ivar_mutation?(def_node.body)
      end

      def ivar_mutation?(node)
        return false if node.nil? || node.is_a?(Prism::DefNode)
        return true if node.is_a?(Prism::CallNode) && MutationWidening::SHAPE_MUTATORS.include?(node.name) &&
                       ivar_rooted?(node.receiver)

        node.rigor_each_child { |child| return true if ivar_mutation?(child) }
        false
      end

      def ivar_rooted?(receiver)
        receiver = RemoverHolderScan.unparenthesised(receiver)
        receiver = receiver.receiver while receiver.is_a?(Prism::CallNode) && ELEMENT_READS.include?(receiver.name)
        receiver.is_a?(Prism::InstanceVariableReadNode)
      end

      # A `send` / `public_send` / `__send__` with a literal Symbol or String name as the call it makes (`a.send(:push,
      # x)` and `a.send("push", x)` are `a.push(x)`), or nil. A name that is no valid string names no method.
      def literal_send_target(call_node)
        return nil unless SEND_NAMES.include?(call_node.name) && call_node.block.nil?

        arguments = call_node.arguments&.arguments
        target = arguments&.first
        return nil unless target.is_a?(Prism::SymbolNode) || target.is_a?(Prism::StringNode)
        return nil unless target.unescaped.valid_encoding?

        rest = arguments.drop(1)
        call_node.copy(name: target.unescaped.to_sym,
                       arguments: rest.empty? ? nil : call_node.arguments.copy(arguments: rest))
      end

      def facts_for(scope)
        frame = scope.match_frame
        body = frame&.body
        return nil if body.nil?

        table = (Thread.current[FACTS_CACHE_KEY] ||= ObjectSpace::WeakKeyMap.new)
        facts = (table[body] ||= scan(body, frame.parameters))
        facts.held.empty? && facts.held_part.empty? && facts.links.empty? ? nil : facts
      end

      # One walk ({SiteCollector}) answers the facts. A body that calls `binding` or `eval` stops it early: every local
      # is aliased, and the foreign locals are read in a walk of their own.
      def scan(body, parameters)
        collector = SiteCollector.new
        result = RemoverHolderScan.unsafe_names(body, parameters, collector)
        if result.equal?(ALL)
          foreign, entry = ForeignLocals.collect(body, parameters)
          return Facts.new(held: ALL, held_part: NO_KEYS, links: NO_LINKS, foreign:, entry:, deferred: NO_LINKS,
                           memo: {}.compare_by_identity, named_memo: {}.compare_by_identity)
        end

        foreign, entry = ForeignLocals.finish(parameters, collector.foreign, collector.written)
        Facts.new(held: collector.held.freeze, held_part: collector.held_part.freeze, links: collector.links.freeze,
                  foreign:, entry:, deferred: collector.deferred.freeze,
                  memo: {}.compare_by_identity, named_memo: {}.compare_by_identity)
      end

      # A site's key ({SiteCollector}) is the start of the outermost loop or block that holds it (it may run again after
      # any later point inside that loop), else where it has handed its locals on: its end (the receiver of a call has
      # handed its locals on before the call's message runs, while the call's own arguments are handed on by the call
      # itself), or its block's start. A local's key is its least site's; a capture by a closure that may run later is
      # {ALWAYS}.
      # Where a site has handed its locals on: a call's block may receive them as soon as it starts.
      def handed_by(node)
        block = node.block if node.is_a?(Prism::CallNode)
        block.is_a?(Prism::BlockNode) ? block.location.start_offset : node.location.end_offset
      end

      # The targets of `call_node` through its receiver, computed once per call site.
      def call_targets(facts, call_node)
        facts.memo.fetch(call_node) { facts.memo[call_node] = yield }
      end

      # The targets of a write through the local `read` reads (a written argument, a receiver), computed once per read.
      # The read is the call's own operand, so its call's offset is fixed with it.
      def read_targets(facts, read)
        facts.named_memo.fetch(read) { facts.named_memo[read] = yield }
      end

      # Whether `scope` binds a local other than `except` (a name, a list of names, or nil) whose type the block
      # accepts: the cheap gate every trigger asks before the body scan, since a floor changes only such a binding.
      def local_besides?(scope, except)
        scope.locals.each { |name, type| return true if !excepted?(except, name) && yield(type) }
        false
      end

      def excepted?(except, name)
        except.is_a?(Symbol) ? except == name : except&.include?(name)
      end

      def each_target(scope, targets, &)
        return scope.locals.each_key { |name| yield name, FULL } if targets.equal?(ALL)

        targets.each(&)
      end

      # Each target but `except` takes what the block answers for its binding. A target reached only below its own
      # object (a depth past {FULL}) is floored only when its binding can hold a mutable element.
      def floor_targets(scope, targets, except)
        acc = scope
        each_target(scope, targets) do |name, kind|
          next if excepted?(except, name)

          current = acc.local(name)
          next if current.nil? || (kind > FULL && !mutable_parts?(current))

          floored = yield(current)
          acc = acc.with_mutated_local(name, floored) unless floored.nil? || floored == current
        end
        acc
      end
    end
  end
end
