# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "refine_census"

module Rigor
  module Inference
    # ADR-121 WD7 — the one function that answers what `self` a `refine` (or a `:refine` literal) at a program point
    # runs on. The in-effect walk ({InEffectRefinements}) works a {Context} out with these functions for every body,
    # method and block it enters and records it for each `refine`-shaped node; the census (`ScopeIndexer`'s module-body
    # walk and its scan of method and refine bodies) reads that record back ({InEffectRefinements#refine_context}), so
    # the table and the activations charge the same module.
    module RefineSelf
      # `here`, for a `refine` call directly at that point; `literal`, for a `:refine` literal there (which names
      # `Module#refine` for an alias or a `send` whose method runs where a method defined there does: in a module's
      # `class << self` body that is the module, though a `refine` call there runs on the singleton class); and
      # `instance` / `singleton`, for a method defined there on the instance / singleton side. Each is a module name,
      # the wildcard (a module the walk cannot name), {CLASS}, {MAIN} or {ANONYMOUS}. `deferred` is true inside a method
      # body (a `def`, a `define_method` block), where a `refine` runs only once the method is called.
      Context = Data.define(:here, :literal, :instance, :singleton, :deferred)
      # A plain class, or an instance of one: `Class` undefines `refine`, so a `refine` there is the class's own
      # method (#1689) and a `:refine` literal is data.
      CLASS = :class
      # The top level's `main`, which has no `refine`.
      MAIN = :main
      # A module a bare `Module.new { … }` creates, which the census names by its position.
      ANONYMOUS = :anonymous

      # Core iteration methods: the Enumerable protocol never rebinds `self` in their block.
      CORE_ITERATORS = Set[
        :each, :each_with_index, :each_with_object, :each_pair, :each_key, :each_value, :map, :flat_map, :times,
        :select, :reject
      ].freeze
      LITERALS = [Prism::ArrayNode, Prism::HashNode, Prism::RangeNode, Prism::IntegerNode, Prism::FloatNode,
                  Prism::StringNode, Prism::InterpolatedStringNode, Prism::SymbolNode].freeze
      NAMED_RECEIVERS = [Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::LocalVariableReadNode,
                         Prism::InstanceVariableReadNode].freeze
      METHOD_BLOCK_CALLS = Set[:define_method, :define_singleton_method].freeze
      INSTANCE_EVAL_CALLS = Set[:instance_eval, :instance_exec].freeze
      # Bindings of a local or an instance variable that are not a plain write: each may hold any value.
      VARIABLE_BINDINGS = [
        Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
        Prism::LocalVariableTargetNode, Prism::RequiredParameterNode, Prism::OptionalParameterNode,
        Prism::RestParameterNode, Prism::KeywordRestParameterNode, Prism::RequiredKeywordParameterNode,
        Prism::OptionalKeywordParameterNode, Prism::BlockParameterNode, Prism::BlockLocalVariableNode,
        Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode,
        Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableTargetNode
      ].freeze
      # Bindings of a constant other than a bare `K = …`, matched by the constant's last segment.
      CONSTANT_BINDINGS = [
        Prism::ConstantOrWriteNode, Prism::ConstantOperatorWriteNode, Prism::ConstantAndWriteNode,
        Prism::ConstantTargetNode, Prism::ConstantPathTargetNode
      ].freeze
      CONSTANT_PATH_BINDINGS = [
        Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathOperatorWriteNode,
        Prism::ConstantPathAndWriteNode
      ].freeze

      private_constant :CORE_ITERATORS, :LITERALS, :NAMED_RECEIVERS, :METHOD_BLOCK_CALLS, :INSTANCE_EVAL_CALLS,
                       :VARIABLE_BINDINGS, :CONSTANT_BINDINGS, :CONSTANT_PATH_BINDINGS

      module_function

      def wildcard = RefineCensus.wildcard

      # The top level: `main`; a method defined there is `Object`'s, which any module may run.
      def top = context(MAIN, wildcard, MAIN)

      # A body whose `self` the walk cannot name.
      def unknown = context(wildcard, wildcard, wildcard)

      def context(here, instance, singleton, deferred: false, literal: here)
        Context.new(here: here, literal: literal, instance: instance, singleton: singleton, deferred: deferred)
      end

      # A `module` body (or a `Module.new` block) of the module `name` (nil when the walk cannot name it, or
      # {ANONYMOUS}): its instance methods run on whatever includes or extends it, its singleton methods on it.
      def module_body(name)
        return unknown if name.nil?

        context(name, wildcard, name)
      end

      # A `class` body (or a `Class.new` / `Struct.new` / `Data.define` block): `self` is a class; a `Module`
      # subclass's instances are modules the walk cannot name.
      def class_body(module_subclass) = context(CLASS, module_subclass ? wildcard : CLASS, CLASS)

      # A `class << expr` body: `self` is a singleton class, so a `refine` call there is its own method; for
      # `class << self` its methods (and a `:refine` literal an alias there names) run on the enclosing `self`, for any
      # other expression on an object the walk cannot name.
      def singleton_class_body(parent, of_self)
        runs_on = of_self ? parent.singleton : wildcard
        context(CLASS, runs_on, CLASS, literal: runs_on)
      end

      # A method body defined in `parent` on the instance or singleton side: `self` is what that side runs on, and a
      # method defined inside it is defined on something the walk cannot name.
      def method_body(parent, singleton)
        context(singleton ? parent.singleton : parent.instance, wildcard, wildcard, deferred: true)
      end

      # The context inside the block of `node` (a block-carrying call, or a lambda) written in `parent`. `eval_name`
      # is the module a `*_eval` / `*_exec` call's constant receiver names, or nil; the given block answers whether a
      # constant, local or instance variable receiver holds a literal ({.keeps_self?}). A block keeps `self` only where
      # its call is known to: a core iteration method on a receiver whose value is a literal in this file, and a
      # `refine` call (its body is the refinement, handled by the reader). A `*_eval` / `*_exec` block runs on its
      # receiver, a `define_method` / `define_singleton_method` block is a method body, and a `Module.new` /
      # `Class.new` block is a module / class body. Any other block (a DSL may `module_eval` it, `tap`, `loop`, a
      # project method, a core method's name on any other receiver), a lambda, and every block at the top level may
      # run under any `self`.
      def block(parent, node, eval_name, &)
        return unknown if node.is_a?(Prism::LambdaNode)
        return parent if node.name == :refine
        return eval_body(parent, node, eval_name) if RefineCensus::SELF_EVAL_CALLS.include?(node.name)
        return meta_new_body(node) if ScopeIndexer.meta_new_constant_rvalue?(node)
        return unknown if parent.here == MAIN
        return method_body(parent, node.name == :define_singleton_method) if method_block?(node)
        return parent if keeps_self?(node, &)

        unknown
      end

      def method_block?(node) = METHOD_BLOCK_CALLS.include?(node.name) && RefineCensus.self_call?(node)

      def meta_new_body(node)
        ScopeIndexer.module_new_call?(node) ? module_body(ANONYMOUS) : class_body(false)
      end

      # A core iteration method on a receiver whose value is a literal in this file: a literal, or a constant, local
      # or instance variable the block answers true for ({.literal_bindings}). Any other name, even on a literal, and
      # any other receiver may be a project method that runs the block under another `self`: on Ruby 4.0.5
      # `Config.each { refine(String) { … } }` with `def self.each(&blk) = Ext.module_eval(&blk)` refines for `Ext`,
      # and so does `[1].configure { … }` with `class Array; def configure(&blk) = Ext.module_eval(&blk); end`.
      def keeps_self?(node)
        return false unless CORE_ITERATORS.include?(node.name)

        receiver = node.receiver
        return true if literal?(receiver)

        NAMED_RECEIVERS.any? { |klass| receiver.is_a?(klass) } && block_given? && yield(receiver)
      end

      def literal?(node) = LITERALS.any? { |klass| node.is_a?(klass) }

      # A literal, or a literal's `.freeze`.
      def literal_value?(node)
        return true if literal?(node)

        node.is_a?(Prism::CallNode) && node.name == :freeze && node.arguments.nil? && node.block.nil? &&
          literal?(node.receiver)
      end

      # The constants (by qualified name), locals and instance variables (by name) that `root` binds, every binding a
      # plain write of a literal ({.literal_value?}). A name any other binding gives a value (a parameter, a
      # multiple assignment, `||=`, `+=`, a `const_set`, a path write `A::K = …`) is not one, wherever in the file
      # it sits.
      def literal_bindings(root)
        literal = Set.new
        other = Set.new
        spoiled = ScopeIndexer.loose_constant_segments(root).dup
        collect_bindings(root, [], literal, other, spoiled)
        (literal - other).reject { |key| key.is_a?(String) && spoiled.include?(key.split("::").last) }.to_set.freeze
      end

      def collect_bindings(node, prefix, literal, other, spoiled)
        case node
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
          return collect_declaration_bindings(node, prefix, literal, other, spoiled)
        when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode
          bind(node.value, node.name, literal, other)
        when *VARIABLE_BINDINGS then other << node.name if node.name
        else collect_constant_binding(node, prefix, literal, other, spoiled)
        end
        node.compact_child_nodes.each { |child| collect_bindings(child, prefix, literal, other, spoiled) }
      end

      def collect_constant_binding(node, prefix, literal, other, spoiled)
        case node
        when Prism::ConstantWriteNode then bind(node.value, (prefix + [node.name.to_s]).join("::"), literal, other)
        when *CONSTANT_BINDINGS then spoiled << node.name.to_s
        when *CONSTANT_PATH_BINDINGS then spoiled << node.target.name.to_s
        end
      end

      # A `class` / `module` body's constants are its own; a `class << expr` body's are the singleton class's, which
      # no read outside it names.
      def collect_declaration_bindings(node, prefix, literal, other, spoiled)
        if node.is_a?(Prism::SingletonClassNode)
          collect_bindings(node.expression, prefix, literal, other, spoiled)
          inner = prefix + ["<singleton>"]
        else
          inner = Source::ConstantPath.declaration_prefix(prefix, node.constant_path) || prefix
          superclass = node.is_a?(Prism::ClassNode) && node.superclass
          collect_bindings(superclass, prefix, literal, other, spoiled) if superclass
        end
        collect_bindings(node.body, inner, literal, other, spoiled) if node.body
      end

      def bind(value, key, literal, other) = (literal_value?(value) ? literal : other) << key

      # The key {.literal_bindings} holds for a receiver read in `prefix`: a constant's innermost lexical candidate (the
      # one Ruby's lookup finds once this file's write defines it), a local's or an instance variable's name.
      def binding_key(receiver, prefix)
        case receiver
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          ScopeIndexer.constant_receiver_candidates(receiver, prefix).first
        else receiver.name
        end
      end

      # A `*_eval` / `*_exec` block: on `self` (or no receiver) it keeps `self`, on a constant it runs on the module the
      # constant names, on anything else on a module the walk cannot name. A `def` in an `instance_eval` binds on the
      # receiver's singleton, so its instance side is the receiver itself.
      def eval_body(parent, node, eval_name)
        here = RefineCensus.self_call?(node) ? parent.here : eval_name
        return context(CLASS, CLASS, CLASS, deferred: parent.deferred) if here == CLASS
        return unknown unless here.is_a?(String) || here == ANONYMOUS
        return unknown if here == wildcard

        instance = INSTANCE_EVAL_CALLS.include?(node.name) ? here : wildcard
        context(here, instance, here, deferred: parent.deferred)
      end

      # The module a context's `refine` call (or, with `literal`, its `:refine` literal) refines for, as a name a table
      # row can hold: the module, else the wildcard.
      def charged_module(context, literal: false)
        here = literal ? context.literal : context.here
        here.is_a?(String) ? here : wildcard
      end
    end
  end
end
