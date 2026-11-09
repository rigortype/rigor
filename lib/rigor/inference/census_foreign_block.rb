# frozen_string_literal: true

require "prism"

require_relative "anonymous_meta_class"

module Rigor
  module Inference
    # Issue #2490 — a block, inside an instance body of a class `K`, whose `self` is provably not an instance of `K`, so
    # an `@x` write directly in it writes some other object's ivar and the class-ivar censuses must not credit it to
    # `K`. Read syntactically, before any type is known, by both the per-file census ({ScopeIndexer}) and the cross-file
    # {IvarWriterCensus}. False positives come first, so a receiver that may hold a `K` instance keeps the credit:
    #
    # - `instance_eval` / `instance_exec` on a receiver that is provably no `K` instance ({.provably_other?}): a
    #   constant or `self.class` (a class object), `X.new` / `X.allocate` on a constant `X` not spelling `K`, a
    #   literal. Any other receiver (a parameter, a local, `dup`, `itself`) may be a `K` and still counts;
    # - `class_eval` / `module_eval` / `class_exec` / `module_exec` on an explicit receiver: `self` is the receiver
    #   module, so `@x` directly in the block is that module object's own ivar;
    # - `define_method` on a constant not spelling `K` (its block runs on that class's instances), and
    #   `define_singleton_method` on a class object or a literal;
    # - a `Class.new` / `Module.new` / `Struct.new` / `Data.define` block: `self` is the new class.
    #
    # `class << obj` inside an instance body is one more barred body; the callers bar it themselves, since it is no
    # call. Only a barred body's own statements are dropped: a `define_method` block nested in a `class_eval` or
    # `class << obj` body whose module may be `K` or an instance's singleton class runs on a `K` instance and still
    # counts, and so does a receiver-less `def` nested in either (#2941, {.reentry_blocks}).
    # `def.ivar-write-mismatch`'s collector reads the same rule (#2943, {.census_children}).
    module CensusForeignBlock
      INSTANCE_EVALS = %i[instance_eval instance_exec].to_set.freeze
      MODULE_EVALS = %i[class_eval module_eval class_exec module_exec].to_set.freeze
      DEFINERS = %i[define_method define_singleton_method].to_set.freeze
      SEND_CALLS = %i[send public_send __send__].to_set.freeze
      # The constructors whose receiver names the class of the object they answer.
      CONSTRUCTORS = %i[new allocate].to_set.freeze
      # The literal receivers, none of them an instance of a project class.
      LITERALS = [Prism::StringNode, Prism::InterpolatedStringNode, Prism::SymbolNode, Prism::IntegerNode,
                  Prism::FloatNode, Prism::ArrayNode, Prism::HashNode, Prism::RangeNode, Prism::RegularExpressionNode,
                  Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::LambdaNode].freeze
      # The calls that answer a module of their receiver.
      MODULE_OF_INSTANCE = %i[class singleton_class].to_set.freeze
      # The constants naming a module every class has among its ancestors, whose methods an instance runs.
      ANCESTOR_ROOTS = %w[Object BasicObject Kernel].to_set.freeze
      # The calls whose answer is foreign when their receiver is: the object itself, a copy, a new instance, its class.
      FOREIGN_PRESERVING = %i[new allocate dup clone itself class singleton_class].to_set.freeze
      # Issue #2983 — the scalar literals, whose blockless calls answer no instance of a project class, unlike a
      # container's (`[k].first`) or a lambda's.
      SCALAR_LITERALS = (LITERALS - [Prism::ArrayNode, Prism::HashNode, Prism::LambdaNode]).freeze
      # A String or Symbol literal that spells a constant path, which a call may resolve to the class
      # (`"K".constantize`).
      CONSTANT_SPELLING = /\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*\z/
      # Separates the qualifications of a {.candidate_key}; no constant name holds it.
      CANDIDATE_SEPARATOR = "|"
      BARRIERS = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
      NONE = [].freeze
      # Every name {.foreign?} can answer true for, so any other call returns at one Set probe.
      CALLS = (INSTANCE_EVALS | MODULE_EVALS | DEFINERS | %i[new define]).freeze

      module_function

      # Whether `node`'s literal block runs with a `self` that is provably not an instance of `class_name`.
      def foreign?(node, class_name)
        unless node.is_a?(Prism::CallNode) && CALLS.include?(node.name) && node.block.is_a?(Prism::BlockNode)
          return false
        end
        return true if AnonymousMetaClass.block_form_receiver(node)

        name = node.name
        receiver = node.receiver
        return false if self_node?(receiver)
        return true if MODULE_EVALS.include?(name)
        return provably_other?(receiver, class_name) if INSTANCE_EVALS.include?(name)
        return provably_other?(receiver, class_name) if name == :define_singleton_method

        foreign_constant?(receiver, class_name)
      end

      # A receiver that is provably no instance of `class_name`: a constant or `self.class` (a class object, `K`
      # itself included), `X.new` / `X.allocate` on a constant `X` not spelling `class_name`, or a literal.
      def provably_other?(receiver, class_name)
        case receiver
        when Prism::ConstantReadNode, Prism::ConstantPathNode then true
        when Prism::CallNode
          return receiver.arguments.nil? if receiver.name == :class

          CONSTRUCTORS.include?(receiver.name) && foreign_constant?(receiver.receiver, class_name)
        else LITERALS.any? { |klass| receiver.is_a?(klass) }
        end
      end

      # A constant that does not spell `class_name`.
      def foreign_constant?(node, class_name)
        (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && !own_class?(node, class_name)
      end

      # The children of `node` a census walk for `class_name` still descends into when `node` runs code whose `self`
      # is another object, or nil for an ordinary node: a {.foreign?} call keeps its receiver and arguments, and a
      # `class << obj` body its expression; both keep the code nested in them that runs on a `class_name` instance
      # again ({.reentry_blocks}) unless `reentry` is false, as it is in a singleton-side `def`, whose `self.class`
      # and `singleton_class` are no module of an instance. A reentered `def` comes back as the {Prism::DefNode},
      # which a walk that stops at a `def` skips and the class-ivar census walks into (#2941).
      def census_children(node, class_name, reentry: true)
        case node
        when Prism::SingletonClassNode
          return [node.expression] unless reentry

          [node.expression, *reentry_blocks(node, class_name)]
        when Prism::CallNode
          return nil unless foreign?(node, class_name)
          return [node.receiver, node.arguments].compact unless reentry

          [node.receiver, node.arguments, *reentry_blocks(node, class_name)].compact
        end
      end

      # The code inside barred code whose `self` may again be an instance of `class_name`, in a `class_eval`-family
      # block whose module may be `class_name` or the singleton class of one of its instances ({.foreign_module?}) or in
      # a `class << obj` body on an operand {.provably_other?} does not name:
      #
      # - a `define_method` block on the implicit or `self` receiver, called directly or through `send` /
      #   `public_send` / `__send__` with the literal name;
      # - a receiver-less `def` (#2941), which defines an instance method of that module, or a singleton method of
      #   the `class << obj` operand, just as the `define_method` does.
      #
      # Ruby runs each on a `K` instance (a `K` method, or a singleton method of the instance), so its writes are
      # `K`'s; an untyped receiver keeps the credit, as {.foreign?} keeps it for `instance_eval`.
      def reentry_blocks(node, class_name)
        body =
          case node
          when Prism::SingletonClassNode then node.body unless provably_other?(node.expression, class_name)
          when Prism::CallNode
            node.block.body if MODULE_EVALS.include?(node.name) && !foreign_module?(node.receiver, class_name)
          end
        return NONE if body.nil?

        found = []
        collect_define_method_blocks(body, found)
        found
      end

      # A `class_eval` receiver whose module is provably neither `class_name`, an ancestor of it nor an instance's
      # singleton class, read from inside an instance body. A receiver chain is foreign only when it is:
      #
      # - rooted at a constant other than `class_name`'s own spelling and {ANCESTOR_ROOTS} (`Other.class_eval`,
      #   `Other.dup`), a `X.new` or `Class.new` on such a constant among them, or rooted at a literal, through
      #   {FOREIGN_PRESERVING} calls only;
      # - `.class` / `.singleton_class` on a receiver {.provably_other?} names (`Other.new.class`, `"s".class`,
      #   `self.class.class`);
      # - rooted at a scalar literal through blockless calls of any name (`"s".upcase.class`, #2983), unless the
      #   literal is a String or Symbol that spells a constant (`"K".constantize`).
      #
      # A `superclass` call may answer an ancestor (`Other.superclass` is `Object`), a `const_get` or registry call may
      # answer the class (`Other.const_get(:K)`), and every other receiver
      # (`self.class`, `singleton_class`, a parameter's `o.class`, `self.class.base_class`) may name `class_name`, so
      # they keep the credit. Parentheses are looked through. The rule is syntactic: a constant naming another
      # ancestor of the class (`Base.class_eval` with `K < Base`), an alias of it or one of its instances reads as
      # foreign here, and the cross-file census files the barred block's code under that constant instead
      # ({.root_constant}), whose entries the class's census joins (#2983).
      def foreign_module?(receiver, class_name)
        receiver = unwrap(receiver)
        return true if scalar_literal_rooted?(receiver)

        case receiver
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          foreign_constant?(receiver, class_name) && !ANCESTOR_ROOTS.include?(receiver.slice.delete_prefix("::"))
        when Prism::CallNode then foreign_module_call?(receiver, class_name)
        else LITERALS.any? { |klass| receiver.is_a?(klass) }
        end
      end

      # A call in the chain keeps it foreign only when it answers its receiver's own object, a copy, a new instance
      # or its class ({FOREIGN_PRESERVING}); any other call (`const_get`, a registry's `fetch`, `superclass`) may
      # answer the class, so the receiver may be it.
      def foreign_module_call?(call, class_name)
        if MODULE_OF_INSTANCE.include?(call.name) && call.arguments.nil? &&
           provably_other?(unwrap(call.receiver), class_name)
          return true
        end
        return false unless FOREIGN_PRESERVING.include?(call.name)

        foreign_module?(call.receiver, class_name)
      end

      # Issue #2983 — whether `receiver` is a chain of blockless calls rooted at a scalar literal that spells no
      # constant: whatever the calls are, Ruby's methods on such a literal answer no project class or its instance.
      def scalar_literal_rooted?(receiver)
        node = receiver
        while node.is_a?(Prism::CallNode)
          return false if node.block

          node = unwrap(node.receiver)
        end
        return false if node.equal?(receiver) || SCALAR_LITERALS.none? { |klass| node.is_a?(klass) }

        !((node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)) && CONSTANT_SPELLING.match?(node.unescaped))
      end

      # Issue #2983 — the constant a `class_eval` receiver chain is rooted at through {FOREIGN_PRESERVING} calls
      # (`Anc`, `INST.class`, `AliasK.new.class`, `Other.singleton_class`), as its candidate key under `nesting`
      # ({.candidate_key}), or nil. The module such a chain names is the constant's, its class's or its singleton's,
      # so the code a barred block reenters runs on the constant's instances or on the object it holds; the
      # cross-file census files it under the key, and a class whose census joins the constant the key resolves to (an
      # ancestor, an alias, an instance constant of it) sees the write.
      def root_constant(receiver, nesting)
        node = unwrap(receiver)
        node = unwrap(node.receiver) while node.is_a?(Prism::CallNode) && FOREIGN_PRESERVING.include?(node.name)
        return unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

        candidate_key(node.slice, nesting)
      end

      # Review round 1 of #3001 — the qualifications a constant spelled `spelling` may have under the lexical
      # `nesting` (the enclosing class and module names), nearest first as Ruby's lookup tries them, joined by
      # {CANDIDATE_SEPARATOR}: `Anc` under `N::K` is `"N::K::Anc|N::Anc|Anc"`. A rooted `::Anc`, or one at the top
      # level, has the one candidate `"Anc"`. `ScopeIndexer::IvarContributions` resolves the key to the first
      # candidate the project declares.
      def candidate_key(spelling, nesting)
        return spelling.delete_prefix("::") if spelling.start_with?("::") || nesting.empty?

        nesting.size.downto(0).map { |depth| [*nesting.first(depth), spelling].join("::") }.join(CANDIDATE_SEPARATOR)
      end

      # Issue #2983 — for a constant write `C = K` or `C = K.new` / `K.allocate` under the lexical `nesting`, the
      # census entry `[:binds_class, key, name]`: `K`'s {.candidate_key} and `C`'s qualified name (a path write's
      # as written), else nil. `C` is an alias or an instance of the class `K` resolves to.
      def binding_entry(node, nesting)
        value = unwrap(node.value)
        value = value.receiver if value.is_a?(Prism::CallNode) && CONSTRUCTORS.include?(value.name) && value.block.nil?
        return unless value.is_a?(Prism::ConstantReadNode) || value.is_a?(Prism::ConstantPathNode)

        name = node.is_a?(Prism::ConstantWriteNode) ? [*nesting, node.name].join("::") : node.target.slice
        [:binds_class, candidate_key(value.slice, nesting), name.delete_prefix("::")].freeze
      end

      # Issue #2983 — the module a String `class_eval` / `module_eval` may define methods on, for
      # `IvarWriterCensus#record_string_eval`: `owner`, the class owning a class body, for an implicit or `self`
      # receiver there (one in an instance body raises); `instance`, the instance body's class, for a receiver
      # {.foreign_module?} does not bar; otherwise the receiver chain's root constant ({.root_constant}); or nil.
      def string_eval_target(node, instance, owner)
        return (owner unless instance) if self_node?(node.receiver)
        return instance if instance && !foreign_module?(node.receiver, instance)

        nesting = instance || owner
        root_constant(node.receiver, nesting ? nesting.split("::") : NONE)
      end

      # For a barred `class_eval`-family block whose receiver {.foreign_module?} takes as another module and whose
      # chain is rooted at a constant ({.root_constant}), that constant's candidate key and the code in the block that
      # runs on its module's instances, as {.reentry_blocks} collects it; else nil.
      def rooted_reentry(node, class_name)
        return unless MODULE_EVALS.include?(node.name) && foreign_module?(node.receiver, class_name)

        root = root_constant(node.receiver, class_name.split("::"))
        return if root.nil?

        found = []
        collect_define_method_blocks(node.block.body, found)
        [root, found]
      end

      # `node` with any parentheses around a single expression looked through.
      def unwrap(node)
        while node.is_a?(Prism::ParenthesesNode)
          body = node.body
          body = body.body.first if body.is_a?(Prism::StatementsNode) && body.body.size == 1
          break if body.nil? || body.is_a?(Prism::StatementsNode)

          node = body
        end
        node
      end

      def collect_define_method_blocks(node, found)
        return unless node.is_a?(Prism::Node)
        return found << node if node.is_a?(Prism::DefNode) && node.receiver.nil?
        return if BARRIERS.any? { |klass| node.is_a?(klass) }

        if node.is_a?(Prism::CallNode)
          return found << node.block if define_method_call?(node)
          return if node.block.is_a?(Prism::BlockNode) && CALLS.include?(node.name)
        end

        node.rigor_each_child { |child| collect_define_method_blocks(child, found) }
      end

      # A `define_method` with a literal block on the implicit or `self` receiver, called directly or through a `send`
      # whose first argument is the literal name.
      def define_method_call?(node)
        return false unless node.is_a?(Prism::CallNode) && self_node?(node.receiver)
        return false unless node.block.is_a?(Prism::BlockNode)
        return true if node.name == :define_method
        return false unless SEND_CALLS.include?(node.name)

        first = node.arguments&.arguments&.first
        (first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)) && first.unescaped == "define_method"
      end

      # `self.class`, or a constant spelling `class_name`.
      def own_class?(node, class_name)
        case node
        when Prism::CallNode
          node.name == :class && self_node?(node.receiver) && node.arguments.nil?
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          spelled = node.slice.delete_prefix("::")
          spelled == class_name || spelled == class_name.split("::").last
        else
          false
        end
      end

      def self_node?(node) = node.nil? || node.is_a?(Prism::SelfNode)
    end
  end
end
