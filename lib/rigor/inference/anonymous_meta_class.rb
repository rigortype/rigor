# frozen_string_literal: true

require "prism"

require_relative "../type/anonymous_class_name"

module Rigor
  module Inference
    # #319 — identity for the class a `Class.new do ... end` / `Module.new do ... end` creates away from
    # constant-write position.
    #
    # Ruby evaluates such a block with `self` bound to the freshly created class (`class_eval` semantics): a
    # `def` inside it defines an instance method on that class and `attr_reader` runs as a class-level macro.
    # `ScopeIndexer` has always walked that body as a class body — but only through its
    # `Prism::ConstantWriteNode` branch, because the constant supplied the name the discovered-method tables
    # are keyed by. At every other position (`klass = Class.new do ... end`, a bare expression, a method
    # return) there was no name, so the body fell through to the enclosing — usually top-level — scope. Two
    # false positives followed on correct code: `attr_reader` became a `call.unresolved-toplevel` warning
    # (`Scope#toplevel?` is `self_type.nil?`), and the class itself typed as the bare `Singleton[Object]`
    # `MethodDispatcher#class_new_lift` hands back, taking `Object`'s zero-arity `new` with it.
    #
    # This module supplies the missing name: a per-call-site synthetic one, spelled so that no Ruby constant
    # path can collide with it in the discovery tables, and stable across the index pass and the dispatch
    # pass because both derive it from the same `(call node, source path)` pair.
    module AnonymousMetaClass
      module_function

      # The class-creating meta calls whose block body is a class body. `Struct.new` / `Data.define` are here
      # because the body semantics are identical — the block is `class_eval`'d on the generated subclass — not
      # because their anonymous *value* is modelled: those keep the `StructClass` / `DataClass` carriers
      # {MethodDispatcher::StructFolding} / {MethodDispatcher::DataFolding} build for them.
      META_NEW_SELECTORS = { Class: :new, Module: :new, Struct: :new, Data: :define }.freeze

      # The receiver constant name (`:Class`, `:Module`, `:Struct`, `:Data`) of a class-creating meta call that
      # carries a literal block, or nil for anything else. The receiver MUST be the bare constant (or its
      # `::`-rooted spelling) — a call through a variable or another call's return has no statically known
      # identity, exactly as `ScopeIndexer#meta_constant_receiver?` requires.
      #
      # Argument shapes are deliberately NOT inspected: `Class.new(Base) { ... }` and
      # `Data.define(*members) { ... }` evaluate their block as a class body whatever the arguments are, and a
      # narrower gate here would leave the body in top-level scope again.
      def block_form_receiver(node)
        return nil unless node.is_a?(Prism::CallNode)
        return nil unless node.block.is_a?(Prism::BlockNode)

        receiver_name = literal_constant_name(node.receiver)
        return nil if receiver_name.nil?
        return nil unless META_NEW_SELECTORS[receiver_name] == node.name

        receiver_name
      end

      # The synthetic class name for `node`'s block body, or nil when `node` is not a recognised block form.
      # {Type::AnonymousClassName} owns the spelling; this decides which call sites earn one and what the key
      # holds.
      #
      # `source_path` is part of the key so two files whose anonymous classes happen to share a line and column
      # do not merge their method sets when the per-file tables are folded into the cross-file seed. It is
      # omitted when the caller has no path (unit-level probes over a bare `Prism` program) — passed through
      # verbatim rather than defaulted, so every pass over the same file derives the same name.
      def name_for(node, source_path = nil)
        receiver_name = block_form_receiver(node)
        return nil if receiver_name.nil?

        location = node.location
        key = [source_path, location.start_line, location.start_column].compact.join(":")
        Type::AnonymousClassName.build(receiver_name, key)
      end

      # The bare-constant receiver's name (`Class`, `::Class`), or nil for every other receiver shape.
      def literal_constant_name(node)
        case node
        when Prism::ConstantReadNode
          node.name
        when Prism::ConstantPathNode
          node.name if node.parent.nil?
        end
      end
    end
  end
end
