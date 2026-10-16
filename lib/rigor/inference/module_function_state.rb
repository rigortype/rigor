# frozen_string_literal: true

require "prism"
require_relative "../source/literals"
require_relative "../source/node_children"

module Rigor
  module Inference
    # The one home for what a receiverless `module_function` call does to the methods around it
    # ([#1507](https://github.com/rigortype/rigor/issues/1507),
    # [#1197](https://github.com/rigortype/rigor/issues/1197)). Four readers used to compute it in four
    # places. They disagree with each other and, in places, with Ruby. Each entry point below reproduces
    # one reader's answer exactly: this module gives the readings one place to live, and does not yet make
    # them agree. A change to one reading lands here, beside the other three.
    #
    # In Ruby a bare `module_function` call turns the body's module_function mode on, and a later bare
    # `public`, `private` or `protected` ({.visibility_reset?}) turns it off again (#1968). A named call
    # (`public :x`, `private def y`) leaves the mode alone, and each `module` body starts with it off. Three
    # readers honour the reset; a reset nested in control flow or a block, which may not run, turns the mode
    # off for them too, so none of them claims a certain module function after it.
    #
    # - The singleton def-node table (`ScopeIndexer#walk_singleton_body`) reads
    #   {.each_singleton_sibling} and {.each_singleton_copy}. A bare call covers the later direct
    #   statements of its own body, up to a reset.
    # - The deferred ranges (`ScopeIndexer#walk_deferred_body`) read {.prescan_deferred} and
    #   {.deferred_module_function?}. A bare call covers every later def by offset, up to a later reset,
    #   and a call or reset inside control flow or a block counts.
    # - The extends table (`ScopeIndexer#record_extend_call`) reads {.extends_self?}. A bare call covers
    #   every instance def of the module, in any order, and is never reset.
    # - sig-gen (`SigGen::Generator#walk_statements`) reads {.each_sig_gen_statement} and
    #   {.sig_gen_module_function?}. A bare call covers the later statements of its own statement list and
    #   what nests in them, up to a reset.
    #
    # A fifth reader does not come here yet: `rigor-activerecord`'s `ModelDiscoverer#table_name_decorators`
    # (`plugins/rigor-activerecord/lib/rigor/plugin/activerecord/model_discoverer.rb`) reads a module body's
    # direct statements for its table-name readers. It also accepts `self.module_function`, and there a bare
    # call covers the instance methods written before it as well as after it, while a named call takes only a
    # def written before it. A change to what `module_function` means must decide whether that reader follows.
    #
    # The deferred-ranges prescan asks `ScopeIndexer.receiver_eval_call?` and `ScopeIndexer.def_singleton?`, so
    # `rigor/inference/scope_indexer` must be loaded before it runs. This file does not require it:
    # `scope_indexer.rb` requires this file, and a require back would be circular. The other entry points need
    # only Prism.
    #
    # `spec/rigor/inference/module_function_state_spec.rb` pins each reader's answers, and marks the ones
    # Ruby contradicts with a "flip this when" note.
    module ModuleFunctionState
      module_function

      # A receiverless `module_function` call, bare or named.
      def call?(node)
        node.name == :module_function && node.receiver.nil?
      end

      # The toggle form: a `module_function` call with no arguments.
      def bare?(node)
        node.arguments.nil? || node.arguments.arguments.empty?
      end

      # A bare `public`, `private` or `protected` call, receiverless or on `self`: Ruby ends the module_function
      # mode there (#1968). A call with arguments sets the named methods' visibility and leaves the mode alone.
      def visibility_reset?(node)
        %i[public private protected].include?(node.name) && bare?(node) &&
          (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
      end

      # Whether `node` holds a {.visibility_reset?} that ends the mode for the statements after it, at any depth
      # {.prescan_deferred} enters. A reset in control flow or a block may not run; the readers that ask take it
      # as run, so they claim no module function after it.
      def resets_mode?(node)
        events = []
        prescan_deferred(node, EMPTY_PREFIX, false, events, [])
        events.any? { |_offset, on| !on }
      end

      # The owner prefix {.resets_mode?} hands the prescan, which records no row a reset needs.
      EMPTY_PREFIX = [].freeze

      # The singleton def-node table's reading, over one class-ish body's direct statements in source
      # order. `ScopeIndexer#statements_of` builds that list, folding a body-level `rescue`, `else` or
      # `ensure` clause into it. Yields `stmt, module_function_on, named_call` for every statement except a
      # bare call:
      #
      # - `module_function_on` says whether a bare call precedes the statement with no statement between them
      #   that {.resets_mode?}.
      # - `named_call` is true for a named call (`module_function :a` or `module_function def x`), which
      #   {.each_singleton_copy} resolves; the caller records nothing else for it.
      #
      # A `module_function` call nested in control flow or a block is not seen, and a reset there turns the
      # toggle off.
      def each_singleton_sibling(statements)
        module_function_on = false
        statements.each do |stmt|
          if stmt.is_a?(Prism::CallNode) && call?(stmt)
            if bare?(stmt)
              module_function_on = true
            else
              yield stmt, module_function_on, true
            end
            next
          end
          yield stmt, module_function_on, false
          module_function_on = false if module_function_on && resets_mode?(stmt)
        end
      end

      # The defs a named call copies onto the module's singleton, for the singleton def-node table. Ruby
      # copies the method in effect at the call (#1550), so a later def of the name redefines only the
      # instance method. This reading approximates that from the body's direct `statements`: it yields
      # `name, def_node` for each Symbol or String argument, where `def_node` is the last receiverless def
      # of that name written as a direct statement before the call.
      #
      # A name declines (nothing is yielded) when no def precedes the call, where Ruby raises `NameError` or
      # copies a def another file may load first, and when a statement after that def and before the call
      # may rebind it in a way this reading cannot name: a def nested in control flow or a block, an `alias`,
      # an `undef`, or a receiverless or `self.` `alias_method`, `define_method`, `attr_*`, `remove_method`
      # or `undef_method` call. Such a call or `alias` with a non-literal name anywhere before the call, even
      # before the def, declines every name. A `module_function def x` argument names nothing here.
      #
      # It does not see `send(:define_method, ...)`, a `define_method` on an explicit module receiver, a
      # `prepend`, another file's singleton defs, or that a `rescue` clause's statements may run after an
      # `ensure` call's (#1969).
      def each_singleton_copy(call, statements)
        call_start = call.location.start_offset
        in_effect = {}
        statements.each do |stmt|
          next unless stmt.location.end_offset <= call_start

          if stmt.is_a?(Prism::DefNode)
            in_effect[stmt.name] = stmt if stmt.receiver.nil?
          else
            each_rebound_name(stmt) { |name| in_effect[name] = :unknown }
          end
        end
        call.arguments&.arguments&.each do |arg|
          name = symbol_argument_name(arg)
          def_node = name && !in_effect.key?(ANY_NAME) && in_effect[name]
          yield name, def_node if def_node.is_a?(Prism::DefNode)
        end
      end

      # The key {.each_singleton_copy} records when a statement may rebind a name it cannot read.
      ANY_NAME = Object.new.freeze

      # Calls that may define, alias or remove an instance method of the receiverless module.
      REBINDING_CALLS = %i[
        alias_method define_method attr attr_reader attr_writer attr_accessor remove_method undef_method
      ].freeze

      # The deferred-ranges reading, over one class-ish body's subtree. Appends to `offsets` an
      # `[offset, true]` event for the start of every bare call and an `[offset, false]` one for every
      # {.visibility_reset?}; a def is a module function when the last event before it is a bare call
      # ({.deferred_module_function?}). Appends to `ranges` one row per named call, in the table's
      # `[start, end, name, kind, owner]` shape:
      #
      # - a `:name` argument gives a `:singleton` row over the call itself, because the copy happens at
      #   the call and not at the def;
      # - a `module_function def x` argument gives a `:both` row over the def, or a `:singleton` row for
      #   `def self.x`.
      #
      # The prescan looks through control flow and blocks, because a call that ran there still flips the
      # later defs. It stops at a nested class, module, `class <<` or def body, where the call targets
      # another module. It skips an `END` body, which runs after every def, and a `*_eval` / `*_exec`
      # block, whose self is the receiver's module; that block gets its own prescan as a body. A reset
      # nested in control flow or a block counts as run, as a bare call there does.
      #
      # `qualified_prefix` names the owner, and `in_singleton_class` says whether the body is a
      # `class <<` body; both feed `ScopeIndexer.def_singleton?`.
      def prescan_deferred(node, qualified_prefix, in_singleton_class, offsets, ranges)
        return unless node.is_a?(Prism::Node)
        return if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) ||
                  node.is_a?(Prism::SingletonClassNode) || node.is_a?(Prism::DefNode) ||
                  node.is_a?(Prism::PostExecutionNode)

        if node.is_a?(Prism::CallNode)
          return prescan_call(node, qualified_prefix, in_singleton_class, offsets, ranges) if call?(node)
          return offsets << [node.location.start_offset, false] if visibility_reset?(node)
          if ScopeIndexer.receiver_eval_call?(node)
            return prescan_eval_call(node, qualified_prefix, in_singleton_class, offsets, ranges)
          end
        end

        node.rigor_each_child do |child|
          prescan_deferred(child, qualified_prefix, in_singleton_class, offsets, ranges)
        end
      end

      # Whether the deferred-ranges reading makes a def starting at `start` a module function: the last
      # event {.prescan_deferred} recorded before it, at any depth the prescan entered, is a bare call.
      def deferred_module_function?(offsets, start)
        last = offsets.select { |offset, _on| offset < start }.max_by(&:first)
        last ? last[1] : false
      end

      # The extends table's reading. A bare call makes the module extend itself, so every instance def the
      # module has also answers on its singleton. That holds for defs before and after the call, and
      # whatever a later `public` or `private` says. The over-approximation is deliberate (#526): the
      # extra names only silence `call.undefined-method` on calls that raise. The walk reaches a call in
      # control flow, and one in a `class_eval`-family block under that block's receiver. It does not reach
      # one in an ordinary block, an `END` body or a `class << self` body.
      def extends_self?(call)
        call?(call) && bare?(call)
      end

      # sig-gen's reading, over one statement list. Yields every statement except a bare call, with
      # whether a bare call came before it in this list or `active` was already true on entry. The
      # generator passes the enclosing list's answer into an `if`, a block or a `begin`, but not into a
      # nested class, module or `class << self`. A bare call in a nested list covers only that list's
      # later statements. A statement that {.resets_mode?} ends it for the statements after it, and a named
      # call is not a directive at all.
      def each_sig_gen_statement(statements, active)
        statements.each do |stmt|
          if sig_gen_directive?(stmt)
            active = true
            next
          end
          yield stmt, active
          active = false if active && resets_mode?(stmt)
        end
      end

      # A bare receiverless call, as sig-gen's statement-level directive.
      def sig_gen_directive?(node)
        node.is_a?(Prism::CallNode) && call?(node) && bare?(node)
      end

      # Whether sig-gen renders a def as `def self?.name`: an instance-side def under an active directive,
      # in a class or a module alike. `kind` is `:singleton` for `def self.x` and a `class << self` body.
      def sig_gen_module_function?(active, kind)
        active && kind == :instance
      end

      # Yields each instance-method name `node` may rebind on the module whose body holds it, or
      # {ANY_NAME} when one is not a literal. It does not enter a nested class, module or `class <<` body,
      # whose methods belong to another module.
      def each_rebound_name(node, &)
        case node
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode then nil
        when Prism::DefNode then yield node.name if node.receiver.nil?
        else
          each_own_rebound_name(node, &)
          node.compact_child_nodes.each { |child| each_rebound_name(child, &) }
        end
      end

      # The names `node` itself may rebind, apart from its children: an `alias`, an `undef` or a
      # {REBINDING_CALLS} call on the module.
      def each_own_rebound_name(node, &)
        case node
        when Prism::AliasMethodNode then yield symbol_argument_name(node.new_name) || ANY_NAME
        when Prism::UndefNode then node.names.each { |name| yield symbol_argument_name(name) || ANY_NAME }
        when Prism::CallNode
          each_rebinding_call_name(node, &) if REBINDING_CALLS.include?(node.name) &&
                                               (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        end
      end

      # The names a {REBINDING_CALLS} call may rebind: the first argument of `alias_method` and
      # `define_method`, every argument of the others (and its writer, for the `attr_*` family), or
      # {ANY_NAME} for a non-literal one.
      def each_rebinding_call_name(call)
        arguments = call.arguments&.arguments || []
        arguments = arguments.first(1) if %i[alias_method define_method].include?(call.name)
        arguments.each do |arg|
          name = symbol_argument_name(arg)
          next yield(ANY_NAME) unless name

          yield name
          yield :"#{name}=" if call.name.start_with?("attr")
        end
      end

      # The prescan's call arm.
      def prescan_call(node, qualified_prefix, in_singleton_class, offsets, ranges)
        if bare?(node)
          offsets << [node.location.start_offset, true]
        else
          owner = qualified_prefix.empty? ? nil : qualified_prefix.join("::")
          node.arguments&.arguments&.each do |arg|
            if arg.is_a?(Prism::DefNode)
              kind = ScopeIndexer.def_singleton?(arg, qualified_prefix, in_singleton_class) ? :singleton : :both
              ranges << [arg.location.start_offset, arg.location.end_offset, arg.name, kind, owner]
            elsif (name = symbol_argument_name(arg))
              ranges << [node.location.start_offset, node.location.end_offset, name, :singleton, owner]
            else
              prescan_deferred(arg, qualified_prefix, in_singleton_class, offsets, ranges)
            end
          end
        end
        return unless node.block

        prescan_deferred(node.block, qualified_prefix, in_singleton_class, offsets, ranges)
      end

      # The prescan's eval arm: only the call's receiver and arguments keep this module's context.
      def prescan_eval_call(node, qualified_prefix, in_singleton_class, offsets, ranges)
        prescan_deferred(node.receiver, qualified_prefix, in_singleton_class, offsets, ranges) if node.receiver
        node.arguments&.arguments&.each do |arg|
          prescan_deferred(arg, qualified_prefix, in_singleton_class, offsets, ranges)
        end
      end

      # The Symbol a `:name` or `"name"` literal argument names, or nil.
      def symbol_argument_name(arg)
        Source::Literals.symbol_or_string(arg)
      end

      private_class_method :prescan_call, :prescan_eval_call, :symbol_argument_name, :each_rebound_name,
                           :each_own_rebound_name, :each_rebinding_call_name
    end
  end
end
