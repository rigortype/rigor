# frozen_string_literal: true

require "prism"

require_relative "../inference/declaration_walk"

module Rigor
  # {Reflection}'s per-file declaration walk for plugins (ADR-128, #2708): {.class_declarations_in} answers which
  # classes a parsed file declares under their `Module.nesting`-correct names, and hands each call inside a
  # declaration body to a plugin together with the class or module its position reaches. It replaces a plugin's own
  # `DeclarationWalk::Collector`, so the walk's context, its control constants and its collector protocol stay
  # internal.
  module Reflection
    # One `class` header of a file, as {.class_declarations_in} reports it.
    #
    # - `name` — the qualified name the header's body is keyed under (`"Admin::User"` for `class User` in
    #   `module Admin`, and for `class Admin::User`); never empty.
    # - `nesting` — `Module.nesting` where the header is written, innermost first, not counting the class itself
    #   (`["Admin"]` for `class User` in `module Admin`; `[]` at the top level). Frozen.
    # - `node` — the `Prism::ClassNode`, for its `superclass` and `body`.
    ClassDeclaration = Data.define(:name, :nesting, :node)

    # One call the walk visited, as {.class_declarations_in} yields it.
    #
    # - `node` — the `Prism::CallNode`.
    # - `owner` — the qualified name of the innermost `class` / `module` the call is lexically inside, or nil where
    #   none is (the top level, or below a bare header in a `class << self` body).
    DeclaredCall = Data.define(:node, :owner)

    module_function

    # ADR-128, #2708 — the classes a parsed file declares, in the order their headers are written. A class
    # reopened in the file appears once per header. A `module`, a `class << self` and a class no name reaches
    # (`Class.new { … }`, a header below `class << self`) are not reported.
    #
    # With a block, the walk also yields a {DeclaredCall} for the calls the engine's declaration walk visits, in
    # source order, outer calls before the calls inside them. Those are the calls in statements and in the bodies of
    # `class` / `module` / `class << self` / blocks, at any depth. The owner is lexical, not `self`: a call in
    # `class << self` or in a `Class.new { … }` block reports the class around it.
    #
    # The block does not see every call node of the file. The walk does not enter, so the block never sees:
    #
    # - a class or module header's own expressions: the superclass (`class Foo < Struct.new(:a)`) and the constant
    #   path (`class foo::Bar`);
    # - the factory call a constant write binds (`K = Class.new { … }`), whose receiver, arguments and block body the
    #   walk does enter;
    # - the tail of such a write (`K = Class.new { … }.freeze` yields what is inside the block, not `freeze`), and
    #   the constant-path parent of a write target (`P` in `P::K = …`).
    #
    # `root` is a `Prism::Node`, typically `Prism.parse(source).value`.
    def class_declarations_in(root, &on_call)
      collector = on_call ? DeclarationCallCollector.new(on_call) : DeclarationCollector.new
      Inference::DeclarationWalk.run(root, [collector], Inference::DeclarationWalk::Context.root(nesting: []))
      collector.classes
    end

    # The walk's collector behind {.class_declarations_in}; the plugin never sees it.
    class DeclarationCollector
      include Inference::DeclarationWalk::Collector

      EMPTY_NESTING = [].freeze

      attr_reader :classes

      def initialize
        @classes = []
      end

      def on_declaration(node, context, body_context)
        if node.is_a?(Prism::ClassNode)
          name = body_context.prefix.join("::")
          @classes << ClassDeclaration.new(name: name, nesting: frozen_nesting(context), node: node) unless name.empty?
        end
        Inference::DeclarationWalk::DESCEND
      end

      private

      # The walk's chain, frozen: the root's `[]` is one array shared by every top-level declaration.
      def frozen_nesting(context)
        nesting = context.nesting || EMPTY_NESTING
        nesting.frozen? ? nesting : nesting.dup.freeze
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
        @on_call.call(DeclaredCall.new(node: node, owner: owner.empty? ? nil : owner))
        Inference::DeclarationWalk::DESCEND
      end
    end
    private_constant :DeclarationCollector, :DeclarationCallCollector
  end
end
