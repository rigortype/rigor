# frozen_string_literal: true

require "prism"

module Rigor
  module Effects
    # Which side of its class a definition written at some point lands on, and what `self` its body runs
    # on. The scanner keys a unit `Class.m` or `Class#m` from the first, and scans the body with the second
    # (the singleton bit {MutationClassifier} and {LocalOwnership.constructor?} read).
    #
    # Ruby answers the two from different places, which is why one bit carried down the walk got both
    # wrong in turn:
    #
    # - a receiver-less `def` lands on the **default definee**: the class the lexically enclosing body
    #   opened, which is the singleton class inside `class << self`. A method body does not move it, so
    #   `def inner` inside `def self.outer` defines `Foo#inner`, while inside a `def` in `class << self` it
    #   defines `Foo.inner`.
    # - `define_method` and the `attr_*` macros are calls on **`self`**, so they define instance methods of
    #   the module `self` is: `Foo#x` inside `def self.setup`, where `self` is `Foo`, and `Foo.x` inside
    #   `class << self`, where it is `Foo`'s singleton class.
    #
    # Both are read off the syntax, so only the spellings that name the new `self` move them: `class << self`,
    # and a block given to `class_eval` / `instance_eval` (or an `_exec` / `module_` alias) on `self` or on
    # `singleton_class`. Every other block keeps the context it closed over — `Other.class_eval { … }` and
    # `obj.instance_eval { … }` included, whose definitions land on a class or object the scanner does not
    # key. So does a `def self.x` in an instance method, which defines a method on one object: it stays
    # keyed `Class.x`, and is scanned as running on an instance, which it does.
    #
    # `self_kind` is `:instance`, `:class` (the class the enclosing namespace opened), or `:singleton_class`
    # (that class's singleton class). There are six contexts, each allocated once.
    class DefinitionContext < Data.define(:self_kind, :definee_singleton)
      CLASS_EVAL_CALLS = %i[class_eval class_exec module_eval module_exec].to_set.freeze
      INSTANCE_EVAL_CALLS = %i[instance_eval instance_exec].to_set.freeze
      private_constant :CLASS_EVAL_CALLS, :INSTANCE_EVAL_CALLS

      CONTEXTS = %i[instance class singleton_class].to_h do |self_kind|
        [self_kind, [false, true].to_h do |definee|
          [definee, new(self_kind: self_kind, definee_singleton: definee)]
        end.freeze]
      end.freeze
      private_constant :CONTEXTS

      def self.of(self_kind, definee_singleton)
        CONTEXTS.fetch(self_kind).fetch(definee_singleton)
      end

      # A class body, and where the walk starts outside one (a top-level `def` is `<toplevel>#m`).
      CLASS_BODY = of(:class, false)
      # A `class << self` body: `self` and the definee are both the singleton class.
      SINGLETON_CLASS_BODY = of(:singleton_class, true)
      # The body of an instance method of the class.
      INSTANCE_METHOD_BODY = of(:instance, false)

      # Whether `self` is a class object here — the singleton bit a unit's body is scanned with.
      def singleton?
        self_kind != :instance
      end

      # Whether a `define_method` or an `attr_*` macro written here defines singleton methods.
      def self_singleton_class?
        self_kind == :singleton_class
      end

      # A `def`, as `[keyed singleton, the context of its body]`. The body keeps this default definee:
      # a `def` nested in it lands where one written beside it would.
      #
      # `def self.x` stays keyed singleton wherever it is written, and its body runs on this `self`. A
      # receiver other than `self` keeps the reading it has always had (a class), since the scanner keys
      # the unit under the enclosing class either way.
      def def_target(node)
        receiver = node.receiver
        if receiver.nil?
          [definee_singleton, DefinitionContext.of(definee_singleton ? :class : :instance, definee_singleton)]
        elsif receiver.is_a?(Prism::SelfNode)
          [true, self]
        else
          [true, DefinitionContext.of(:class, definee_singleton)]
        end
      end

      # A literal-name `define_method`, as `[keyed singleton, the context of its block body]`. The block
      # keeps the definee it closed over. `self` as an instance has no `define_method`, so that shape
      # raises at run time and keeps the instance key it has always had.
      def define_method_target
        singleton = self_singleton_class?
        [singleton, DefinitionContext.of(singleton ? :class : :instance, definee_singleton)]
      end

      # The context `child` runs under as a child of `node`. A call's block and a `class <<` body may
      # rebind `self`; every other child keeps this context. (A block is a call's only `BlockNode` child.)
      def for_child(node, child)
        case node
        when Prism::CallNode then child.is_a?(Prism::BlockNode) ? block(node) : self
        when Prism::SingletonClassNode then child.equal?(node.body) ? singleton_class_body : self
        else self
        end
      end

      private

      # The context of a `class << …` body. Only `self` as the class moves it; the scanner has always read
      # any `class << expr` in a class body as the class's own singleton, and still does.
      def singleton_class_body
        self_kind == :class ? SINGLETON_CLASS_BODY : self
      end

      def block(call)
        name = call.name
        if CLASS_EVAL_CALLS.include?(name) then class_eval_block(call.receiver)
        elsif INSTANCE_EVAL_CALLS.include?(name) then instance_eval_block(call.receiver)
        else self
        end
      end

      # `class_eval` makes its receiver both `self` and the definee: on `self`, the class `self` already is;
      # on `singleton_class`, the singleton class.
      def class_eval_block(receiver)
        if self_receiver?(receiver)
          return self if self_kind == :instance

          DefinitionContext.of(self_kind, self_kind == :singleton_class)
        elsif self_kind == :class && singleton_class_call?(receiver)
          SINGLETON_CLASS_BODY
        else
          self
        end
      end

      # `instance_eval` makes its receiver `self` and the receiver's singleton class the definee, so on a
      # class `self` a `def` inside defines a singleton method while a `define_method` still defines an
      # instance one.
      def instance_eval_block(receiver)
        self_kind == :class && self_receiver?(receiver) ? DefinitionContext.of(:class, true) : self
      end

      def self_receiver?(receiver)
        receiver.nil? || receiver.is_a?(Prism::SelfNode)
      end

      def singleton_class_call?(receiver)
        receiver.is_a?(Prism::CallNode) && receiver.name == :singleton_class && self_receiver?(receiver.receiver) &&
          receiver.arguments.nil? && receiver.block.nil?
      end
    end
  end
end
