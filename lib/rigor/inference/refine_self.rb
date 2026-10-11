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
      # the names a constant's spelling can denote (an Array, innermost first, for a module only another file may
      # declare), the wildcard (a module the walk cannot name), {CLASS}, {MAIN}, {ANONYMOUS} or {REFINEMENT}.
      # `deferred` is true inside a method body (a `def`, a `define_method` block), where a `refine` runs only once the
      # method is called.
      # `own_method` is true inside a singleton `def` of a module the walk names ({.def_body}), and in the blocks that
      # keep its `self`: `here` is then that module itself, so a `refine X do … end` written there refines X for it
      # once the method is called, and the census records its rows where it would otherwise charge a wildcard.
      Context = Data.define(:here, :literal, :instance, :singleton, :deferred, :own_method)
      # A plain class, or an instance of one: `Class` undefines `refine`, so a `refine` there is the class's own
      # method (#1689) and a `:refine` literal is data.
      CLASS = :class
      # The top level's `main`, which has no `refine`.
      MAIN = :main
      # A module a bare `Module.new { … }` creates, which the census names by its position.
      ANONYMOUS = :anonymous
      # The refinement a `refine` block creates, where a method defined on its singleton side (`def self.x`, a
      # `define_singleton_method` block, a `class << self` body) runs. `using` rejects a refinement with `TypeError`,
      # so a `refine` there reaches no `using` span and the census charges it to nothing.
      REFINEMENT = :refinement

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

      def context(here, instance, singleton, deferred: false, literal: here, own_method: false)
        Context.new(here: here, literal: literal, instance: instance, singleton: singleton, deferred: deferred,
                    own_method: own_method)
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

      # A `def` body in `parent`: on no receiver an instance method, on `self` (or on the constant that is the last
      # segment of the module `parent` names, `def M.x` inside `module M`) a singleton one, and on any other object a
      # method defined on something the walk cannot name. A singleton method of a module the walk names is the
      # module's own (`own_method`): `def self.x`, or a `def` written in that module's `class << self`
      # (`parent.instance` is the module there). `self` is then the module itself, whichever way the method is called,
      # so a `refine` in it refines for that module; for an instance `def`, whose `parent.instance` is the wildcard,
      # Ruby runs it on whatever module extends the owner. `def M.x` is not marked, as the constant names the module by
      # its last segment only.
      def def_body(parent, receiver)
        return mark_own_method(method_body(parent, false)) if receiver.nil?
        return unknown.with(deferred: true) unless lexical_self_receiver?(receiver, parent)

        context = method_body(parent, true)
        receiver.is_a?(Prism::SelfNode) ? mark_own_method(context) : context
      end

      def mark_own_method(context) = named_module?(context.here) ? context.with(own_method: true) : context

      def lexical_self_receiver?(receiver, context)
        return true if receiver.is_a?(Prism::SelfNode)

        here = context.here
        receiver.is_a?(Prism::ConstantReadNode) && here.is_a?(String) && here.split("::").last == receiver.name.to_s
      end

      # A module name the walk can charge a `refine` to: not the wildcard, {CLASS}, {MAIN} or {ANONYMOUS}, and not the
      # several names a constant's spelling can denote.
      def named_module?(here) = here.is_a?(String) && here != wildcard

      # The context inside the block of `node` (a block-carrying call, or a lambda) written in `parent`. `eval_names`
      # are the modules a `*_eval` / `*_exec` call's constant receiver may name ({.eval_receiver_names}), or nil; the
      # given block answers whether a constant, local or instance variable receiver holds a literal ({.keeps_self?}).
      # A block keeps `self` only where its call is known to: a core iteration method on a receiver whose value is a
      # literal in this file, and a `refine` call (its body is the refinement, handled by the reader). A `*_eval` /
      # `*_exec` block runs on its receiver, a `define_method` / `define_singleton_method` block is a method body, and
      # a `Module.new` / `Class.new` block is a module / class body. Any other block (a DSL may `module_eval` it,
      # `tap`, `loop`, a project method, a core method's name on any other receiver), a lambda, and every block at the
      # top level may run under any `self`.
      def block(parent, node, eval_names, &)
        return unknown if node.is_a?(Prism::LambdaNode)
        return refinement_body(parent) if node.name == :refine
        return eval_body(parent, node, eval_names) if RefineCensus::SELF_EVAL_CALLS.include?(node.name)
        return meta_new_body(node) if ScopeIndexer.meta_new_constant_rvalue?(node)
        return unknown if parent.here == MAIN
        return method_body(parent, node.name == :define_singleton_method) if method_block?(node)
        return parent if keeps_self?(node, &)

        unknown
      end

      def method_block?(node) = METHOD_BLOCK_CALLS.include?(node.name) && RefineCensus.self_call?(node)

      # The block of a `refine` call: a `refine` written in it (a nested one) is charged where the call is, but `self`
      # is the refinement, so a method defined in it is defined on something the walk cannot name: a singleton method
      # on the refinement itself ({REFINEMENT}, whichever the method the `refine` call sits in, as long as the module it
      # refines for is one), an instance method on an instance of the refined class (the wildcard), not on the module
      # around.
      def refinement_body(parent)
        singleton = module_here?(parent.here) ? REFINEMENT : parent.singleton
        parent.with(instance: refinement_side(parent.instance), singleton: singleton, own_method: false)
      end

      def refinement_side(side) = side.is_a?(String) || side.is_a?(Array) ? wildcard : side

      # Is `here` a module a `refine` there refines for (so its block is a refinement's body), or the refinement itself?
      def module_here?(here) = named_module?(here) || here.is_a?(Array) || here == ANONYMOUS || here == REFINEMENT

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
        node.rigor_each_child { |child| collect_bindings(child, prefix, literal, other, spoiled) }
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
      # constant names (any name its spelling can denote), on anything else on a module the walk cannot name. A `def` in
      # an `instance_eval` binds on the receiver's singleton, so its instance side is the receiver itself.
      def eval_body(parent, node, eval_names)
        here = RefineCensus.self_call?(node) ? parent.here : eval_names
        here = here.first if here.is_a?(Array) && here.size == 1
        return context(CLASS, CLASS, CLASS, deferred: parent.deferred) if here == CLASS
        return unknown unless here.is_a?(String) || here.is_a?(Array) || here == ANONYMOUS || here == REFINEMENT
        return unknown if here == wildcard

        instance = INSTANCE_EVAL_CALLS.include?(node.name) ? here : wildcard
        context(here, instance, here, deferred: parent.deferred)
      end

      # The modules a `*_eval` / `*_exec` call `node` written in `context` at the lexical `prefix` may run its block
      # on, when its receiver is a constant: every name the constant's spelling can denote, innermost first, as another
      # file may declare any of them (`M.module_eval { … }` in `module L` runs on `L::M` where some file declares it);
      # a `self::`-anchored one as the method walk resolves it (`ScopeIndexer.eval_receiver_prefix`). Else nil.
      def eval_receiver_names(node, prefix, context)
        return nil unless RefineCensus::SELF_EVAL_CALLS.include?(node.name) && !RefineCensus.self_call?(node)

        receiver = node.receiver
        if Source::ConstantPath.qualified_name_or_nil(receiver)
          return ScopeIndexer.constant_receiver_candidates(receiver, prefix)
        end

        here = context.here
        self_prefix = here.is_a?(String) && here != wildcard ? here.split("::") : []
        resolved = ScopeIndexer.eval_receiver_prefix(node, self_prefix, prefix, unnameable_self: self_prefix.empty?)
        [resolved.join("::")] unless resolved.nil? || resolved.empty?
      end

      # The modules a context's `refine` call (or, with `literal`, its `:refine` literal) may refine for, as names a
      # table row can hold: the module, each name a constant's spelling can denote, else the wildcard.
      def charged_modules(context, literal: false)
        here = literal ? context.literal : context.here
        case here
        when String then [here]
        when Array then here
        else [wildcard]
        end
      end
    end
  end
end
