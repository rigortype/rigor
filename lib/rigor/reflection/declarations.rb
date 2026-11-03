# frozen_string_literal: true

require "prism"

require_relative "../inference/declaration_walk"

module Rigor
  # {Reflection}'s per-file declaration walk for plugins (ADR-128, #2708): {.declarations_in} answers which classes a
  # parsed file declares under their `Module.nesting`-correct names, and hands each call to a plugin together with the
  # class or module its position reaches. It replaces a plugin's own `DeclarationWalk::Collector`, so the walk's
  # context, its control constants and its collector protocol stay internal.
  module Reflection
    # One `class` header of a file, as {.declarations_in} reports it.
    #
    # - `name` — the qualified name the header's body is keyed under (`"Admin::User"` for `class User` in
    #   `module Admin`, and for `class Admin::User`); never empty.
    # - `nesting` — `Module.nesting` where the header is written, innermost first, not counting the class itself
    #   (`["Admin"]` for `class User` in `module Admin`; `[]` at the top level).
    # - `node` — the `Prism::ClassNode`, for its `superclass` and `body`.
    ClassDeclaration = Data.define(:name, :nesting, :node)

    module_function

    # ADR-128, #2708 — the classes a parsed file declares, in the order their headers are written. A class
    # reopened in the file appears once per header. A `module`, a `class << self` and a class no name reaches
    # (`Class.new { … }`, a header below `class << self`) are not reported.
    #
    # With a block, the walk also yields the file's `Prism::CallNode`s in source order, outer calls before the calls
    # inside them, each with the qualified name of the innermost `class` / `module` it is lexically inside, or nil
    # where none is (the top level, or below a bare header in a `class << self` body). The owner is lexical, not
    # `self`: a call in `class << self` or in a `Class.new { … }` block reports the class around it. The one call the
    # block does not see is the factory call a constant write binds (`K = Class.new { … }`), whose block body the
    # walk still enters.
    #
    # `root` is a `Prism::Node`, typically `Prism.parse(source).value`.
    def declarations_in(root, &on_call)
      collector = on_call ? DeclarationCallCollector.new(on_call) : DeclarationCollector.new
      Inference::DeclarationWalk.run(root, [collector], Inference::DeclarationWalk::Context.root(nesting: []))
      collector.classes
    end

    # The walk's collector behind {.declarations_in}; the plugin never sees it.
    class DeclarationCollector
      include Inference::DeclarationWalk::Collector

      attr_reader :classes

      def initialize
        @classes = []
      end

      def on_declaration(node, context, body_context)
        if node.is_a?(Prism::ClassNode)
          name = body_context.prefix.join("::")
          @classes << ClassDeclaration.new(name: name, nesting: context.nesting || [], node: node) unless name.empty?
        end
        Inference::DeclarationWalk::DESCEND
      end
    end

    # {DeclarationCollector} that also forwards every call. A subclass, because the walk dispatches only the events a
    # collector's class overrides, so a classes-only run pays for no call event.
    class DeclarationCallCollector < DeclarationCollector
      def initialize(on_call)
        super()
        @on_call = on_call
      end

      def on_call(node, context)
        owner = context.prefix.join("::")
        @on_call.call(node, owner.empty? ? nil : owner)
        Inference::DeclarationWalk::DESCEND
      end
    end
    private_constant :DeclarationCollector, :DeclarationCallCollector
  end
end
