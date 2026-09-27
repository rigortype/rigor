# frozen_string_literal: true

require "prism"
require_relative "../source/node_children"

module Rigor
  module Inference
    # The one home for what a receiverless `module_function` call does to the methods around it
    # ([#1507](https://github.com/rigortype/rigor/issues/1507),
    # [#1197](https://github.com/rigortype/rigor/issues/1197)). Four readers used to compute it in four
    # places. They disagree with each other and, in places, with Ruby. Each entry point below reproduces
    # one reader's answer exactly: this module gives the readings one place to live, and does not yet make
    # them agree. A change to one reading lands here, beside the other three. Examples are #1550's
    # named-form snapshot and the reset a bare `public`, `private` or `protected` makes.
    #
    # - The singleton def-node table (`ScopeIndexer#walk_singleton_body`) reads
    #   {.each_singleton_sibling} and {.each_singleton_copy}. A bare call covers the later direct
    #   statements of its own body and is never reset.
    # - The deferred ranges (`ScopeIndexer#walk_deferred_body`) read {.prescan_deferred} and
    #   {.deferred_module_function?}. A bare call covers every later def by offset, and a call inside
    #   control flow or a block counts.
    # - The extends table (`ScopeIndexer#record_extend_call`) reads {.extends_self?}. A bare call covers
    #   every instance def of the module, in any order.
    # - sig-gen (`SigGen::Generator#walk_statements`) reads {.each_sig_gen_statement} and
    #   {.sig_gen_module_function?}. A bare call covers the later statements of its own statement list and
    #   what nests in them.
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

      # The singleton def-node table's reading, over one class-ish body's direct statements in source
      # order. `ScopeIndexer#statements_of` builds that list, folding a body-level `rescue`, `else` or
      # `ensure` clause into it. Yields `stmt, module_function_on, named_call` for every statement except a
      # bare call:
      #
      # - `module_function_on` says whether a bare call precedes the statement. The toggle never switches
      #   off, although a later bare `public`, `private` or `protected` resets it in Ruby.
      # - `named_call` is true for a named call (`module_function :a` or `module_function def x`), which
      #   {.each_singleton_copy} resolves; the caller records nothing else for it.
      #
      # A call nested in control flow or a block is not seen.
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
        end
      end

      # The defs a named call copies onto the module's singleton, for the singleton def-node table. Yields
      # `name, def_node` for each Symbol or String argument that names a receiverless def among the body's
      # direct `statements`. The last def of that name wins wherever it sits. A def written after the call
      # is therefore taken, although Ruby copies the one in effect at the call (#1550), and a name defined
      # only after the call resolves, although Ruby raises `NameError` there. A `module_function def x`
      # argument names nothing here.
      def each_singleton_copy(call, statements)
        defs_by_name = statements.each_with_object({}) do |stmt, acc|
          acc[stmt.name] = stmt if stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?
        end
        call.arguments&.arguments&.each do |arg|
          name = symbol_argument_name(arg)
          def_node = name && defs_by_name[name]
          yield name, def_node if def_node
        end
      end

      # The deferred-ranges reading, over one class-ish body's subtree. Appends to `offsets` the start of
      # every bare call; each def that starts after one is a module function
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
      # block, whose self is the receiver's module; that block gets its own prescan as a body. Nothing
      # resets it.
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
          if ScopeIndexer.receiver_eval_call?(node)
            return prescan_eval_call(node, qualified_prefix, in_singleton_class, offsets, ranges)
          end
        end

        node.rigor_each_child do |child|
          prescan_deferred(child, qualified_prefix, in_singleton_class, offsets, ranges)
        end
      end

      # Whether the deferred-ranges reading makes a def starting at `start` a module function: a bare call
      # starts before it, at any depth the prescan entered.
      def deferred_module_function?(offsets, start)
        offsets.any? { |offset| offset < start }
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
      # later statements. Nothing resets it, and a named call is not a directive at all.
      def each_sig_gen_statement(statements, active)
        statements.each do |stmt|
          if sig_gen_directive?(stmt)
            active = true
            next
          end
          yield stmt, active
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

      # The prescan's call arm.
      def prescan_call(node, qualified_prefix, in_singleton_class, offsets, ranges)
        if bare?(node)
          offsets << node.location.start_offset
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
        arg.unescaped.to_sym if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
      end

      private_class_method :prescan_call, :prescan_eval_call, :symbol_argument_name
    end
  end
end
