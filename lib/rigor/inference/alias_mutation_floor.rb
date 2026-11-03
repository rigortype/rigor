# frozen_string_literal: true

require "prism"

require_relative "../run_scoped_slots"
require_relative "../source/node_children"
require_relative "closure_escape_analyzer"
require_relative "mutation_widening"
require_relative "receiver_alias"
require_relative "remover_holder_scan"
require_relative "set_mutation"
require_relative "string_mutation"
require_relative "unknown_store_widening"
require_relative "alias_mutation_floor/foreign_locals"

module Rigor
  module Inference
    # Issue #2335 — a local's literal shape describes its object, and a mutation through another path to that object
    # makes it stale: `y = x; y << "s"`, `a.each { |x| x << "s" }` on an Array holding `inner`, `@a = a; @a << "s"`,
    # `h[:k] = a; h[:k] << "s"`, `Hash.new(a)[:k] << "s"`, `[acc].each { |a| poke(a) }`. The named-binding widening
    # ({MutationWidening.widen_after_call}) and the callee floor only rebind the binding a receiver or argument names,
    # so every other local holding the object kept its literal and a later read reported on correct code.
    #
    # One scan per frame body answers:
    #
    # - where each local is handed to another holder, from {RemoverHolderScan}'s walk (a copy, a container element, a
    #   call argument, an ivar or index write's value, a capture by a closure that may run later, a reflective
    #   receiver; every local under `binding` / `eval`). A local is *aliased* at a call once such a site may have run
    #   before it: a site earlier in the body, or one inside a loop or block that also holds the call or ends before
    #   it; a capture by a closure that may run later counts everywhere, and a call inside such a closure sees every
    #   site;
    # - the *foreign* locals: those whose object may have come from elsewhere, so they may be one of the aliased
    #   locals' objects: a method parameter, a block or lambda parameter (but one of a catalogued iterator over
    #   literals that read nothing), a local any target node binds (a multiple assignment, a `rescue => e`, a pattern,
    #   a `for` index), and a local written from anything but a new object.
    #
    # A mutating call whose receiver may be another local's object ({.targets}) gives each local it may reach the
    # unknown store {UnknownStoreWidening.widen_store} gives a site whose stored values nothing typed: the same
    # widening the named path applies, fed `Dynamic[top]` arguments, with its gradual arm. A callee that writes such
    # an argument, and a call on one to a method that mutates its instance variables, floor them the same way. The
    # bindings the receiver itself names are left to the named path, so its precise answer stands.
    #
    # A body where no local is handed on, and a receiver only ever written a new object that is not aliased, change
    # nothing.
    module AliasMutationFloor
      # `escapes` maps each aliased local to the earliest offset its handing-on may run from ({.handed_by}), or is
      # {ALL}; `deferred` lists the `[start, end)` ranges of the closures that may run later.
      # `memo` keeps each call's answer ({.call_targets}) for the run: a loop or block body is evaluated more than once.
      Facts = Data.define(:escapes, :foreign, :entry, :deferred, :memo, :named_memo)
      EMPTY = Set.new.freeze
      ALWAYS = -1
      LOOPS = [Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::BlockNode, Prism::LambdaNode].freeze

      # The {RemoverHolderScan} collector, which reads every fact {.scan} needs in that one walk: for each local the
      # least key of the sites that hand it on ({.handed_by}), the ranges of the closures that may run later, and the
      # body's foreign and written locals ({ForeignLocals.visit}).
      class SiteCollector
        attr_writer :site
        attr_reader :escapes, :deferred, :foreign, :written

        def initialize
          @escapes = {}
          @site = nil
          @outer = nil
          @outer_owner = nil
          @deferred = []
          @foreign = Set.new
          @written = Set.new
          @literal_blocks = Set.new.compare_by_identity
          @def_depth = 0
        end

        def <<(name)
          key = @site ? @outer || AliasMutationFloor.handed_by(@site) : ALWAYS
          current = @escapes[name]
          @escapes[name] = key if current.nil? || key < current
          self
        end

        def enter(node, parent)
          if @outer.nil? && LOOPS.any? { |klass| node.is_a?(klass) }
            @outer = node.location.start_offset
            @outer_owner = node
          end
          note_deferred(node, parent)
          if node.is_a?(Prism::DefNode)
            @def_depth += 1
          elsif @def_depth.zero?
            ForeignLocals.visit(node, @foreign, @written, @literal_blocks)
          end
        end

        def leave(node)
          if node.equal?(@outer_owner)
            @outer = nil
            @outer_owner = nil
          end
          @def_depth -= 1 if node.is_a?(Prism::DefNode)
        end

        # Only a call that may keep its argument hands it to another holder: a constructor, an in-place mutator (a
        # container adder), and a reflective or `define_method` call. Any other call's arguments are passed, not kept.
        def keeps_arguments?(call_node) = KEEPING_CALLS.include?(call_node.name)

        private

        def note_deferred(node, parent)
          return unless node.is_a?(Prism::LambdaNode) ||
                        (node.is_a?(Prism::BlockNode) && RemoverHolderScan.deferred_block?(parent))

          start = node.location.start_offset
          @deferred << [start, start + node.location.length]
        end
      end

      ALL = :all
      NUMBERED_PARAMETER = /\A_[1-9]\z/
      SEND_NAMES = %i[send public_send __send__].to_set.freeze
      KEEPING_CALLS = (MutationWidening::SHAPE_MUTATORS | SetMutation::MUTATORS |
                       %i[new add add? send public_send __send__ instance_variable_set instance_exec instance_eval
                          class_exec module_exec define_method define_singleton_method]).freeze
      ELEMENT_READS = %i[[] first last fetch dig].to_set.freeze
      FACTS_CACHE_KEY = RunScopedSlots.register(:__rigor_alias_mutation_floor_facts)
      IVAR_CACHE_KEY = RunScopedSlots.register(:__rigor_alias_mutation_floor_ivar_mutators)
      FLOOR_CACHE_KEY = RunScopedSlots.register(:__rigor_alias_mutation_floor_callee_floors)
      STORE_CACHE_KEY = RunScopedSlots.register(:__rigor_alias_mutation_floor_unknown_stores)
      private_constant :ALWAYS, :LOOPS, :ALL, :NUMBERED_PARAMETER, :SEND_NAMES, :ELEMENT_READS, :FACTS_CACHE_KEY,
                       :IVAR_CACHE_KEY, :FLOOR_CACHE_KEY, :STORE_CACHE_KEY

      module_function

      # `scope` after `call_node`, a shape mutator ({.candidate?}), ran on a receiver that may be another local's
      # object. The block answers the locals the receiver itself names, whose own widening (the named path's)
      # stands; it runs only once the call has targets.
      def floor_after_call(call_node, scope)
        return scope unless local_besides?(scope, nil) { |type| UnknownStoreWidening.callee_floorable?(type) }

        facts = facts_for(scope)
        return scope if facts.nil?

        targets = call_targets(facts, call_node) do
          receiver_targets(call_node.receiver, facts, aliased_at(facts, call_node))
        end
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

        targets = read_targets(facts, read) { targets(name, facts, aliased_at(facts, call_node)) }
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
          per_call[type] = UnknownStoreWidening.widen_store(type, method_name, arg_types)
        end
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

        targets = read_targets(facts, read) { targets(name, facts, aliased_at(facts, call_node)) }
        return local_besides?(scope, name) { |type| literal_shape?(type) } if targets.equal?(ALL)

        targets.any? { |target| target != name && literal_shape?(scope.local(target)) }
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

      # A literal-symbol `send` / `public_send` / `__send__` as the call it makes (`a.send(:push, x)` is `a.push(x)`),
      # or nil.
      def literal_send_target(call_node)
        return nil unless SEND_NAMES.include?(call_node.name) && call_node.block.nil?

        arguments = call_node.arguments&.arguments
        target = arguments&.first
        return nil unless target.is_a?(Prism::SymbolNode)

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
        facts.escapes.empty? ? nil : facts
      end

      # One walk ({SiteCollector}) answers the facts. A body that calls `binding` or `eval` stops it early: every local
      # is aliased, and the foreign locals are read in a walk of their own.
      def scan(body, parameters)
        collector = SiteCollector.new
        result = RemoverHolderScan.unsafe_names(body, parameters, collector)
        if result.equal?(ALL)
          foreign, entry = ForeignLocals.collect(body, parameters)
          return Facts.new(escapes: ALL, foreign:, entry:, deferred: [].freeze, memo: {}.compare_by_identity,
                           named_memo: {}.compare_by_identity)
        end

        foreign, entry = ForeignLocals.finish(parameters, collector.foreign, collector.written)
        Facts.new(escapes: collector.escapes.freeze, foreign:, entry:, deferred: collector.deferred.freeze,
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

      # The locals aliased by the time `call_node`'s message runs: every one, inside a closure that may run later.
      def aliased_at(facts, call_node)
        escapes = facts.escapes
        return ALL if escapes.equal?(ALL)

        offset = (call_node.message_loc || call_node.location).start_offset
        return escapes.keys.to_set if facts.deferred.any? { |from, to| offset >= from && offset < to }

        escapes.each_with_object(Set.new) { |(name, key), set| set << name if key <= offset }
      end

      # The locals a write through `receiver` may reach: through each local it may evaluate to
      # ({ReceiverAlias.candidates}: `(c ? a : b)`), or as through any other receiver.
      def receiver_targets(receiver, facts, aliased)
        reads = ReceiverAlias.candidates(receiver)
        return targets(nil, facts, aliased) if reads.empty? || !reads.all?(Prism::LocalVariableReadNode)

        reads.map { |read| targets(read.name, facts, aliased) }.reduce { |acc, set| union(acc, set) }
      end

      def union(left, right)
        left.equal?(ALL) || right.equal?(ALL) ? ALL : left | right
      end

      # The locals of `aliased` a write through the local `name` (nil for any other receiver) may reach:
      #
      # - every one, through a receiver that may hold any object: an ivar, an index read, a call result, a block
      #   parameter, or a local some write binds to an object from elsewhere;
      # - only the foreign ones, through a local only ever written a new object or a method parameter the body never
      #   rebinds, once the body has handed it on: either is an object no new-object local can be, and only a holder it
      #   reached can hand it to another local;
      # - none, through such a local the body has not handed on.
      def targets(name, facts, aliased)
        return ALL if aliased.equal?(ALL)
        return aliased if name.nil? || NUMBERED_PARAMETER.match?(name)
        return aliased if facts.foreign.include?(name) && !facts.entry.include?(name)

        aliased.include?(name) ? aliased & facts.foreign : EMPTY
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

      def each_target(scope, targets) = targets.equal?(ALL) ? scope.locals.keys : targets

      # Each target but `except` takes what the block answers for its binding.
      def floor_targets(scope, targets, except)
        each_target(scope, targets).reduce(scope) do |acc, name|
          next acc if excepted?(except, name)

          current = acc.local(name)
          next acc if current.nil?

          floored = yield(current)
          floored.nil? || floored == current ? acc : acc.with_mutated_local(name, floored)
        end
      end
    end
  end
end
