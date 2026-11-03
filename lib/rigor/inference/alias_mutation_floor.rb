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
      # `escapes` maps each aliased local to the earliest offset its handing-on may run from ({.site_keys}), or is
      # {ALL}; `deferred` lists the `[start, end)` ranges of the closures that may run later.
      # `memo` keeps each call's answer ({.call_targets}) for the run: a loop or block body is evaluated more than once.
      Facts = Data.define(:escapes, :foreign, :entry, :deferred, :memo)
      EMPTY = Set.new.freeze
      ALWAYS = -1
      LOOPS = [Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::BlockNode, Prism::LambdaNode].freeze

      # The {RemoverHolderScan} collector that keeps, for each local, the nodes that hand it on (nil for a capture by a
      # closure that may run later).
      class SiteCollector
        attr_writer :site
        attr_reader :sites

        def initialize
          @sites = {}
          @site = nil
        end

        def <<(name)
          (@sites[name] ||= []) << @site
          self
        end

        # Only a call that may keep its argument hands it to another holder: a constructor, an in-place mutator (a
        # container adder), and a reflective or `define_method` call. Any other call's arguments are passed, not kept.
        def keeps_arguments?(call_node) = KEEPING_CALLS.include?(call_node.name)
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
      private_constant :ALWAYS, :LOOPS, :ALL, :NUMBERED_PARAMETER, :SEND_NAMES, :ELEMENT_READS, :FACTS_CACHE_KEY,
                       :IVAR_CACHE_KEY

      module_function

      # `scope` after `call_node`, a shape mutator, ran on a receiver that may be another local's object. `except` names
      # the locals the receiver itself names, whose own widening (the named path's) stands.
      # The caller asks {.candidate?} first, so it computes `except` only for a call this may floor after.
      def floor_after_call(call_node, scope, except: nil)
        facts = facts_for(scope)
        return scope if facts.nil?

        targets = call_targets(facts, call_node, nil) do
          receiver_targets(call_node.receiver, facts, aliased_at(facts, call_node))
        end
        return scope if targets.empty?

        method_name, arg_types = UnknownStoreWidening.unknown_store(call_node)
        floor_targets(scope, targets, except) { |type| UnknownStoreWidening.widen_store(type, method_name, arg_types) }
      end

      # Whether `call_node` is a shape mutator on an explicit receiver, the only call {.floor_after_call} floors after.
      def candidate?(call_node)
        !call_node.receiver.nil? && MutationWidening::SHAPE_MUTATORS.include?(call_node.name)
      end

      # `scope` after `call_node` wrote the object the local `name` holds (a callee that writes its argument or mutates
      # the ivars of an object holding it): every local that may be that object and holds a literal shape
      # ({.literal_shape?}) takes one unknown store ({UnknownStoreWidening.callee_block_floor}). A method parameter the
      # body never rebinds floors nothing here: the callee census reads every opaque hand-off as a write, and flooring
      # each local a parameter was copied into at every such call cost precision across the corpus for no finding (a
      # known limit of #2335).
      def floor_after_written_local(scope, name, call_node)
        facts = facts_for(scope)
        return scope if facts.nil?
        return scope if facts.entry.include?(name)

        targets = call_targets(facts, call_node, name) { targets(name, facts, aliased_at(facts, call_node)) }
        return scope if targets.empty?

        floor_targets(scope, targets, [name]) do |type|
          UnknownStoreWidening.callee_block_floor(type) if literal_shape?(type)
        end
      end

      # Whether {.floor_after_written_local} may floor anything for the local `name` at `call_node`: a target bound to a
      # literal shape.
      def reaches_other_locals?(scope, name, call_node)
        facts = facts_for(scope)
        return false if facts.nil? || facts.entry.include?(name)

        targets = call_targets(facts, call_node, name) { targets(name, facts, aliased_at(facts, call_node)) }
        names = targets.equal?(ALL) ? scope.locals.keys : targets
        names.any? { |target| target != name && literal_shape?(scope.local(target)) }
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

      def scan(body, parameters)
        collector = RemoverHolderScan.unsafe_names(body, parameters, SiteCollector.new)
        foreign, entry = ForeignLocals.collect(body, parameters)
        escapes, deferred = collector.equal?(ALL) ? [ALL, []] : site_keys(body, collector.sites)
        Facts.new(escapes:, foreign:, entry:, deferred:,
                  memo: {}.compare_by_identity)
      end

      # `[escapes, deferred]` for {Facts}: a site's key is the start of the outermost loop or block that holds it (it
      # may run again after any later point inside that loop), else where it has handed them on ({.handed_by}): its end
      # (the receiver of a call has handed its locals on before the call's message runs, while the call's own arguments
      # are handed on by the call itself), or its block's start; a local's is its least site's.
      def site_keys(body, sites)
        site_nodes = Set.new.compare_by_identity
        sites.each_value { |nodes| nodes.each { |node| site_nodes << node if node } }
        node_keys = {}.compare_by_identity
        deferred = []
        walk_sites(body, nil, nil, site_nodes, node_keys, deferred)
        escapes = sites.transform_values do |nodes|
          nodes.map { |node| node ? node_keys.fetch(node, ALWAYS) : ALWAYS }.min
        end
        [escapes.freeze, deferred.freeze]
      end

      def walk_sites(node, parent, outer, site_nodes, node_keys, deferred)
        start = node.location.start_offset
        outer ||= start if LOOPS.any? { |klass| node.is_a?(klass) }
        node_keys[node] = outer || handed_by(node) if site_nodes.include?(node)
        if node.is_a?(Prism::LambdaNode) || (node.is_a?(Prism::BlockNode) && RemoverHolderScan.deferred_block?(parent))
          deferred << [start, start + node.location.length]
        end
        node.rigor_each_child { |child| walk_sites(child, node, outer, site_nodes, node_keys, deferred) }
      end

      # Where a site has handed its locals on: a call's block may receive them as soon as it starts.
      def handed_by(node)
        block = node.block if node.is_a?(Prism::CallNode)
        block.is_a?(Prism::BlockNode) ? block.location.start_offset : node.location.end_offset
      end

      # The targets of `call_node` (through its receiver when `name` is nil, else through the local `name` it writes),
      # computed once per call site.
      def call_targets(facts, call_node, name)
        per_call = (facts.memo[call_node] ||= {})
        per_call.fetch(name) { per_call[name] = yield }
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

      # Each target but `except` takes what the block answers for its binding.
      def floor_targets(scope, targets, except)
        names = targets.equal?(ALL) ? scope.locals.keys : targets
        names.reduce(scope) do |acc, name|
          next acc if except&.include?(name)

          current = acc.local(name)
          next acc if current.nil?

          floored = yield(current)
          floored.nil? || floored == current ? acc : acc.with_mutated_local(name, floored)
        end
      end
    end
  end
end
