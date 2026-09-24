# frozen_string_literal: true

require "prism"

module Rigor
  module Effects
    # Which side of its class a definition written at some point lands on, and what `self` its body runs
    # on, or that the syntax does not say. The scanner keys a unit `Class.m` or `Class#m` from the first, and
    # scans the body with the second (the singleton bit {MutationClassifier} and
    # {LocalOwnership.constructor?} read).
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
    # Only the spellings that name the new `self` move either answer: `class << self`, and a block given to
    # `class_eval` / `instance_eval` (or an `_exec` / `module_` alias) on `self` or on `singleton_class`.
    # Where the syntax cannot say, the answer is **unknown** and a definition there is no unit. That covers
    # the block of `Class.new` and its kin, an eval on any other receiver, `class << obj`, and a method
    # defined on one object or on a singleton class's own singleton class. Filed under the enclosing class,
    # such a definition would join that class's real method of the same name, and a `Class.new(self)`
    # override shares its name by design.
    #
    # `self_kind` is `:instance`, `:class` (the class the enclosing namespace opened), `:singleton_class`
    # (that class's singleton class) or `:unknown`, and `definee_singleton` is true, false, or nil when
    # unknown. Every context is allocated once.
    class DefinitionContext < Data.define(:self_kind, :definee_singleton)
      CLASS_EVAL_CALLS = %i[class_eval class_exec module_eval module_exec].to_set.freeze
      INSTANCE_EVAL_CALLS = %i[instance_eval instance_exec].to_set.freeze
      # The builders whose block defines into a class or module the call itself creates.
      ANONYMOUS_BUILDERS = { Class: :new, Module: :new, Struct: :new, Data: :define }.freeze
      # The `self_kind`s that are a class object.
      CLASS_SELVES = %i[class singleton_class].to_set.freeze
      private_constant :CLASS_EVAL_CALLS, :INSTANCE_EVAL_CALLS, :ANONYMOUS_BUILDERS, :CLASS_SELVES

      CONTEXTS = %i[instance class singleton_class unknown].to_h do |self_kind|
        [self_kind, [false, true, nil].to_h do |definee|
          [definee, new(self_kind: self_kind, definee_singleton: definee)]
        end.freeze]
      end.freeze
      private_constant :CONTEXTS

      def self.of(self_kind, definee_singleton)
        CONTEXTS.fetch(self_kind).fetch(definee_singleton)
      end

      # Whether a child of `node` may run under another context than `node` does: a call's block, or a
      # `class <<` body. Only these need {#for_child}, and asking once per node rather than once per child
      # keeps the walks from paying a call for every element of a large literal.
      def self.rebinds?(node)
        node.is_a?(Prism::SingletonClassNode) || (node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode))
      end

      # A class body.
      CLASS_BODY = of(:class, false)
      # A `class << self` body: `self` and the definee are both the singleton class.
      SINGLETON_CLASS_BODY = of(:singleton_class, true)
      # The body of an instance method of the class.
      INSTANCE_METHOD_BODY = of(:instance, false)
      # The top level, where `self` is `main`, an instance of `Object`, and a `def` defines `Object#m`.
      TOP_LEVEL = INSTANCE_METHOD_BODY
      # Where the syntax says neither what `self` is nor where a `def` lands. Every block inside stays here.
      UNKNOWN = of(:unknown, nil)

      # Whether `self` is a class object here — the singleton bit a unit's body is scanned with.
      def singleton?
        CLASS_SELVES.include?(self_kind)
      end

      # Whether a `define_method` or an `attr_*` macro written here defines singleton methods.
      def self_singleton_class?
        self_kind == :singleton_class
      end

      # The context the body of `def` node `node` runs under, or nil where no key names the method. The
      # unit is keyed singleton exactly when that context is {#singleton?}. The body keeps this default
      # definee: a `def` nested in it lands where one written beside it would.
      #
      # `def self.x` defines a singleton method only where `self` is the class. In an instance method it
      # defines a method on one object, and in `class << self` one on the singleton class's own singleton
      # class. `def Const.x` keeps the reading it has always had, a method of the class the unit is keyed
      # under; any other receiver is an object no key names.
      def def_body(node)
        case node.receiver
        when nil
          DefinitionContext.of(definee_singleton ? :class : :instance, definee_singleton) unless definee_singleton.nil?
        when Prism::SelfNode
          self if self_kind == :class
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          DefinitionContext.of(:class, definee_singleton) unless self_kind == :unknown
        end
      end

      # The context the block of a literal-name `define_method` written here runs under, or nil where no key
      # names the method; an `attr_*` macro here defines on the same side. Both are calls on `self`, which
      # only a class and its singleton class answer, and the block keeps the definee it closed over.
      def module_call_body
        case self_kind
        when :class then DefinitionContext.of(:instance, definee_singleton)
        when :singleton_class then DefinitionContext.of(:class, definee_singleton)
        end
      end

      # The context `child` runs under as a child of `node`, a node {.rebinds?} accepts. A call's block and a
      # `class <<` body may rebind `self`; every other child keeps this context. (A block is a call's only
      # `BlockNode` child.)
      def for_child(node, child)
        case node
        when Prism::CallNode then child.is_a?(Prism::BlockNode) ? block(node) : self
        when Prism::SingletonClassNode then child.equal?(node.body) ? singleton_class_body(node.expression) : self
        else self
        end
      end

      private

      # `class << self` on the class opens its singleton class; any other `class << …` opens one no key names.
      def singleton_class_body(expression)
        self_kind == :class && expression.is_a?(Prism::SelfNode) ? SINGLETON_CLASS_BODY : UNKNOWN
      end

      def block(call)
        name = call.name
        if CLASS_EVAL_CALLS.include?(name) then class_eval_block(call.receiver)
        elsif INSTANCE_EVAL_CALLS.include?(name) then instance_eval_block(call.receiver)
        elsif anonymous_builder?(call) then UNKNOWN
        else self
        end
      end

      # `class_eval` makes its receiver both `self` and the definee.
      def class_eval_block(receiver)
        if self_receiver?(receiver) && singleton? then DefinitionContext.of(self_kind, self_kind == :singleton_class)
        elsif singleton_class_receiver?(receiver) then SINGLETON_CLASS_BODY
        else UNKNOWN
        end
      end

      # `instance_eval` makes its receiver `self` and the receiver's singleton class the definee. On the
      # class that is the singleton class. On the singleton class it is that class's own singleton class,
      # which no key names, so a `define_method` there is keyed and a `def` is not.
      def instance_eval_block(receiver)
        if self_receiver?(receiver) && self_kind == :class then DefinitionContext.of(:class, true)
        elsif (self_receiver?(receiver) && self_kind == :singleton_class) || singleton_class_receiver?(receiver)
          DefinitionContext.of(:singleton_class, nil)
        else UNKNOWN
        end
      end

      def self_receiver?(receiver)
        receiver.nil? || receiver.is_a?(Prism::SelfNode)
      end

      # `singleton_class` called on the class.
      def singleton_class_receiver?(receiver)
        self_kind == :class && receiver.is_a?(Prism::CallNode) && receiver.name == :singleton_class &&
          self_receiver?(receiver.receiver) && receiver.arguments.nil? && receiver.block.nil?
      end

      # `Class.new { … }` and its kin, spelled on the core constant.
      def anonymous_builder?(call)
        receiver = call.receiver
        name = case receiver
               when Prism::ConstantReadNode then receiver.name
               when Prism::ConstantPathNode then receiver.name if receiver.parent.nil?
               end
        !name.nil? && ANONYMOUS_BUILDERS[name] == call.name
      end
    end
  end
end
