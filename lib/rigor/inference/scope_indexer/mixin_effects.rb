# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../../source/node_walker"
require_relative "../declaration_walk/rules"

module Rigor
  module Inference
    module ScopeIndexer
      # The mixin effects and taints, moved out of `scope_indexer.rb` whole (ADR-116 WD9, #3400): what the include
      # walk ({MixinTables}) and the extend walk (`ScopeIndexer.extend_tables`) both ask about a call that mixes a
      # module in, or may. Neither walk is here: each hands these functions the call, the owner it resolved and the
      # {MixinAccumulator} it fills.
      #
      # Eight functions are public, because both walks call each. {.mixin_effects} names the ancestry sides a mixin
      # call reshapes and their owners. {.taint_unrecorded_mixin}, {.taint_computed_mixin_send} and
      # {.taint_opaque_eval} taint an owner side for a call the tables cannot hold: a mixin call the walk did not
      # record (#2991), a `send` whose name is computed (#3006), and an eval block on a receiver nothing names.
      # {.hook_def_params} lists the parameters of a `self.included(base)`-style hook, {.prepend_call_receiver} names
      # the class a constant receiver targets (#1123), {.meta_new_mixin_owner} names the owner a constant write that
      # creates a class gives its block, and {.program_statements} answers the top-level statements of a parsed
      # file. The other 23 are private: the two arms of {.mixin_effects}, the four receiver predicates, the two scans
      # of an eval block, and the fifteen functions that read a computed `send`, which are the hook's taint, the name
      # argument, and the scan for the literals a local or an iterated block parameter can hold (#3024).
      #
      # It asks {DeclarationWalk::Rules} for a receiver's prefix and a class-creating write's, and calls three
      # functions left in `scope_indexer.rb`, recognisers the other walkers ask too, at four sites:
      # `ScopeIndexer.opaque_mixin_argument?` (one), `ScopeIndexer.mixin_call_view` (two) and
      # `ScopeIndexer.lexical_self_receiver?` (one). Three constants moved with it, the ones only it read, private as
      # they were: `LOCAL_SCOPE_BOUNDARIES`, `HOOK_DEFS` and `MIXIN_EVAL_CALLS`. It reads
      # `ScopeIndexer::ARRAY_ITERATORS`, `INSTANCE_MIXIN_NAMES`, `MIXIN_KINDS` and `SEND_CALL_NAMES` lexically, as
      # {NodePropagation} reads the indexer's constants: other rows of `scope_indexer.rb` read each.
      #
      # `scope_indexer.rb` requires this file, and this file does not require it back. It requires the file of what
      # else it names. So the file loads alone, and until `scope_indexer.rb` has loaded it answers where it reaches
      # none of those seven names. {.program_statements}, {.hook_def_params}, {.prepend_call_receiver},
      # {.meta_new_mixin_owner} and {.mixin_effects} answer as they do. {.taint_unrecorded_mixin} answers for no
      # call: one with an argument is a `NoMethodError` (`opaque_mixin_argument?`) and one with none a `NameError`
      # (`INSTANCE_MIXIN_NAMES`). {.taint_computed_mixin_send} answers only when it is handed no class
      # (`SEND_CALL_NAMES`), and {.taint_opaque_eval} until its scan of an eval block meets a call (`MIXIN_KINDS`).
      module MixinEffects # rubocop:disable Metrics/ModuleLength
        module_function

        # The top-level statements of a parsed file: the one body whose declarations need no enclosing
        # declaration to be direct ({MixinAccumulator}).
        def program_statements(root)
          root.is_a?(Prism::ProgramNode) ? root.statements : root
        end

        # Issue #2991 — an unrecorded `include` / `prepend` that reaches the instance side (its receiver is not a
        # `singleton_class` call) leaves that side's module SET unknown when an argument is not a constant
        # (`include(*MODS)`, `include helper`) or the receiver is a hook parameter (`base.include M`), which lists
        # {MixinAccumulator::UNNAMED}. A `Module.new { … }` argument keeps its #2975 reading. A hook's `base.extend M`
        # or `base.singleton_class.include M` taints the instance side's order alone: it mixes nothing into it.
        #
        # Issue #2995 — an instance-side call whose arguments are all constants is recorded wherever the walk names its
        # owner (`self.include M` and a receiverless `send(:include, M)` included), so none reaches here with a module
        # the tables do not hold. The extends walk's taint of `Const.include M` inside `class << self` is the one
        # constant-argument call that does, and the include walk records that edge under `Const`.
        #
        # Issue #2994 — the singleton side lists {MixinAccumulator::UNNAMED} too when an unrecorded call reaching it has
        # an argument that is not a constant: `extend(*EMODS)`, `extend helper`, `include(*MODS)` inside
        # `class << self`, or a `self` argument. A hook parameter's `base.extend(*X)` extends the includer, not the
        # module the hook is written in, so it leaves that module's singleton side unnamed-free.
        def taint_unrecorded_mixin(node, kind, arguments, effects, accumulator)
          opaque = arguments.any? { |arg| ScopeIndexer.opaque_mixin_argument?(arg) }
          hook = hook_parameter_receiver?(node.receiver, accumulator)
          unnamed = INSTANCE_MIXIN_NAMES.include?(kind) && !singleton_class_eval_receiver?(node.receiver) &&
                    (hook || opaque)
          effects.each do |owner, side|
            accumulator.taint(owner, side, unnamed: side == :include ? unnamed : opaque && !hook)
          end
        end

        # A hook parameter itself (`base` in `def self.included(base)`): its class is the includer, which the walk
        # cannot name, so a mixin on it is read as unnamed rather than by its constant (#2991).
        def hook_parameter_receiver?(receiver, accumulator)
          receiver.is_a?(Prism::LocalVariableReadNode) && accumulator.hook_local?(receiver.name)
        end

        # Issue #3006 — a receiverless or `self.` `send` / `public_send` / `__send__` written in a class body
        # ({MixinAccumulator#class_body_scope}) whose name is computed and which passes at least one further argument
        # may be an `include`, `prepend` or `extend` the walk cannot record: it lists {MixinAccumulator::UNNAMED} on
        # `side` of the enclosing class when the name may be one of `kinds`. A name that is a local of the call's scope
        # bound only to name literals is read as those names ({.local_send_names}), so `m = :attr_reader; send(m, :x)`
        # marks nothing. A hook parameter's `base.send(meth, M)` is read wherever the hook is, as
        # {.taint_unrecorded_mixin} reads `base.send(:include, M)`.
        def taint_computed_mixin_send(node, current_class, accumulator, kinds, side, in_singleton: false)
          return unless current_class

          name = computed_send_name(node, accumulator)
          return if name.nil?

          scope = accumulator.class_body_scope(node)
          hook = hook_parameter_receiver?(node.receiver, accumulator)
          return if scope.nil? && !hook

          names = scope && local_send_names(name, scope)
          # Inside `class << self` the instance walk is ownerless, so this walk keeps the hook's instance-side taint
          # too, as {ScopeIndexer.record_extend_call} does for `base.send(:include, M)`.
          sides = in_singleton ? [side, :include] : [side]
          return taint_computed_hook_send(current_class, accumulator, names, sides) if hook
          return if names&.none? { |literal| kinds.any? { |kind| kind.name == literal } }

          accumulator.taint(current_class, side, unnamed: true)
        end

        # A hook parameter's computed `send`, read as {.taint_unrecorded_mixin} reads the literal one: it taints the
        # enclosing module's `sides` when the name may be any mixin's, and lists the unnamed marker on the instance side
        # alone, when the name may be `include` or `prepend`.
        def taint_computed_hook_send(current_class, accumulator, names, sides)
          return if names&.none? { |literal| MIXIN_KINDS.any? { |kind| kind.name == literal } }

          instance = names.nil? || names.any? { |literal| INSTANCE_MIXIN_NAMES.any? { |kind| kind.name == literal } }
          sides.each { |side| accumulator.taint(current_class, side, unnamed: side == :include && instance) }
        end

        # The name argument of a receiverless, `self.` or hook-parameter `send`-family call that passes at least one
        # further argument, when no literal spells it; else nil.
        def computed_send_name(node, accumulator)
          return unless SEND_CALL_NAMES.include?(node.name)
          return unless ScopeIndexer.lexical_self_receiver?(node.receiver) ||
                        hook_parameter_receiver?(node.receiver, accumulator)

          arguments = node.arguments&.arguments
          return if arguments.nil? || arguments.size < 2

          first = arguments.first
          first unless literal_send_name(first)
        end

        LOCAL_SCOPE_BOUNDARIES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
        private_constant :LOCAL_SCOPE_BOUNDARIES

        # The names a local `send` argument can hold: every literal a `local = :name` / `local = "name"` in `scope`
        # writes, or nil when the argument is not a local, or when the local has no such write or any other binding in
        # `scope` — a parameter (the `def`'s or a block's, which may shadow it), a multiple or operator write, a pattern
        # or a regexp capture. Blocks share their scope's locals, so they are searched; a nested `def` or declaration
        # opens a scope of its own, so it is not.
        #
        # Issue #3024 — one block parameter is not opaque: as the FIRST parameter of `each` / `each_with_index` /
        # `map` over a literal array (or a constant the same scope assigns a literal array), it holds each element in
        # turn, so the elements are read as the candidate names ({.iterated_element_source}). An element that is not
        # a name literal still means "may be anything".
        def local_send_names(argument, scope)
          return nil unless argument.is_a?(Prism::LocalVariableReadNode)

          names = []
          root = scope.is_a?(Prism::DefNode) ? scope.compact_child_nodes : [scope]
          return nil unless collect_local_send_names(root, argument.name, names, root)

          names.empty? ? nil : names
        end

        def collect_local_send_names(nodes, local, names, scope_nodes)
          nodes.all? do |node|
            next true if LOCAL_SCOPE_BOUNDARIES.any? { |kind| node.is_a?(kind) }

            iterated = iterated_element_names(node, local, scope_nodes)
            next false if iterated == false

            if iterated
              names.concat(iterated)
              next collect_local_send_names(iterated_element_children(node), local, names, scope_nodes)
            end

            literal = local_send_name_literal(node, local)
            next false if literal == :clash

            names << literal if literal

            collect_local_send_names(node.compact_child_nodes, local, names, scope_nodes)
          end
        end

        # Issue #3024 — the `each` / `each_with_index` / `map` arm of {.collect_local_send_names}: when `node` is
        # such an iterator whose first block parameter is `local`, the iterated array's elements are `local`'s
        # candidate names ({.iterated_element_source}), each read as {.literal_send_name}. False when an element
        # may spell any name; nil when `node` is not that iterator, so the caller's plain-write and binding checks
        # apply.
        def iterated_element_names(node, local, scope_nodes)
          elements = iterated_element_source(node, local, scope_nodes)
          return if elements.nil?
          return false if elements == :unknown

          names = elements.map { |element| literal_send_name(element) }
          return false if names.any?(&:nil?)

          names
        end

        # The name literal a `local = :name` / `local = "name"` write binds `local` to for
        # {.collect_local_send_names}, `:clash` when `node` binds `local` to anything else — a non-literal write,
        # a target, an operator write, a parameter — or nil when `node` does not bind `local` at all.
        def local_send_name_literal(node, local)
          if node.is_a?(Prism::LocalVariableWriteNode) && node.name == local
            name = literal_send_name(node.value)
            return :clash if name.nil?

            return name
          end
          :clash if local_binding?(node, local)
        end

        # Issue #3024 — the array elements `node` iterates when it is an `each` / `each_with_index` / `map` call
        # whose FIRST block parameter is `local`: a literal `ArrayNode` receiver's elements, or a bare constant the
        # same scope assigns a literal array exactly once ({.constant_array_elements}). `:unknown` when the call is
        # such an iterator on `local` but its elements cannot be read — a non-literal receiver, or a constant that
        # is unwritten, multiply written or not array-valued — so the parameter may hold anything; nil when `node`
        # is not the iterator or `local` is not its first parameter.
        def iterated_element_source(node, local, scope_nodes)
          return unless node.is_a?(Prism::CallNode) && ARRAY_ITERATORS.include?(node.name)

          block = node.block
          return unless block.is_a?(Prism::BlockNode)
          return unless iterated_first_parameter?(block, local)

          iterated_receiver_elements(node.receiver, scope_nodes) || :unknown
        end

        # Whether `local` is the first parameter of `block` and no other parameter binds it too (`|m, m = x|` — the
        # later binding wins, so the first is not the element).
        def iterated_first_parameter?(block, local)
          declared = block.parameters
          return false unless declared.is_a?(Prism::BlockParametersNode)

          parameters = declared.parameters
          first = parameters&.requireds&.first
          return false unless first.is_a?(Prism::RequiredParameterNode) && first.name == local

          Source::NodeWalker.each(parameters).none? do |param|
            !param.equal?(first) && local_binding?(param, local)
          end
        end

        # The elements of the array `receiver` denotes for {.iterated_element_source}: a literal array's own, or a
        # bare constant's when the same scope assigns it a literal array exactly once. Nil when it denotes anything
        # else — a qualified or rooted constant, a local, a call — so the iterated value may be anything.
        def iterated_receiver_elements(receiver, scope_nodes)
          return receiver.elements if receiver.is_a?(Prism::ArrayNode)
          return unless receiver.is_a?(Prism::ConstantReadNode)

          constant_array_elements(receiver.name, scope_nodes)
        end

        # The elements of the literal array `name` is assigned in `nodes`' scope, or nil when it is written any
        # other number of times or its value is not an array literal — the constant may then hold anything. Only
        # a single plain `NAME = […]` write closes; in-place mutation (`KINDS << :include`) is unmodeled.
        def constant_array_elements(name, nodes)
          writes = constant_write_nodes(nodes, name)
          return unless writes.one? && writes.first.is_a?(Prism::ConstantWriteNode)

          value = writes.first.value
          value.elements if value.is_a?(Prism::ArrayNode)
        end

        # Every write binding the bare constant `name` in `nodes`' scope — a plain `NAME = …`, a multi-assign
        # target or an operator / `&&=` / `||=` write, mirroring {.local_binding?} — stopping where
        # {.collect_local_send_names} stops, since a nested `def` or declaration binds its own constants — so
        # {.constant_array_elements} can tell one literal-array assignment from none or several.
        def constant_write_nodes(nodes, name)
          nodes.flat_map do |node|
            next [] if LOCAL_SCOPE_BOUNDARIES.any? { |kind| node.is_a?(kind) }

            own = constant_binding?(node, name) ? [node] : []
            own + constant_write_nodes(node.compact_child_nodes, name)
          end
        end

        # A node that binds the bare constant `name`: every `Prism::Constant*` binding class — write, target,
        # operator, `&&=` and `||=` — except the `ConstantReadNode` and `ConstantPath*` spellings, which read
        # `name` or bind a qualified `A::NAME` rather than `name` itself.
        def constant_binding?(node, name)
          return false unless node.respond_to?(:name) && node.name == name

          klass = node.class.name
          klass.start_with?("Prism::Constant") && !klass.start_with?("Prism::ConstantPath") &&
            !node.is_a?(Prism::ConstantReadNode)
        end

        # The children of an iterator call {.iterated_element_source} matched, minus its block's parameters — the
        # first is `local` bound to the elements and the rest bind other names — so the usual scan still sees every
        # other binding of `local` in the receiver, arguments and body.
        def iterated_element_children(node)
          [node.receiver, node.arguments, node.block.body].compact
        end

        # The method name a `send` argument spells: a name literal's, or `""` — no mixin's — for an interpolation with a
        # literal part no mixin name contains (`"#{name}_from_params"`). Nil when it may spell any name.
        def literal_send_name(value)
          return value.unescaped if value.is_a?(Prism::SymbolNode) || value.is_a?(Prism::StringNode)
          return nil unless value.is_a?(Prism::InterpolatedStringNode) || value.is_a?(Prism::InterpolatedSymbolNode)

          excluded = value.parts.any? do |part|
            part.is_a?(Prism::StringNode) && MIXIN_KINDS.none? { |kind| kind.name.include?(part.unescaped) }
          end
          excluded ? "" : nil
        end

        # A node other than a plain write that binds `local`: a target, an operator write or a parameter.
        def local_binding?(node, local)
          return false if node.is_a?(Prism::LocalVariableReadNode) || !node.respond_to?(:name) || node.name != local

          node.class.name.start_with?("Prism::LocalVariable") || node.class.name.end_with?("ParameterNode") ||
            node.is_a?(Prism::BlockLocalVariableNode)
        end

        # `[[owner, side], …]` — the ancestry sides a mixin call reshapes. `self` and the implicit receiver
        # are the enclosing class (`:include` for `include` / `prepend`, `:extend` for `extend`; inside
        # `class << self` `include` / `prepend` flip to `:extend` and `extend` names no owner); `singleton_class` is the
        # singleton side; a constant is that class; any other receiver reshapes nothing, except a hook parameter
        # (`base.include M` in `self.included(base)`), which taints both sides of the enclosing class.
        def mixin_effects(node, kind, qualified_prefix, current_class, accumulator, in_singleton:)
          receiver = node.receiver
          side = kind == :extend ? :extend : :include
          pairs =
            if receiver.nil? || receiver.is_a?(Prism::SelfNode)
              own_mixin_effects(kind, side, current_class, in_singleton)
            else
              receiver_mixin_effects(node, side, qualified_prefix, current_class, accumulator)
            end
          pairs.reject { |owner, _side| owner.nil? }
        end

        # The implicit-receiver / `self` arm of {.mixin_effects}: inside `class << self`, `include` / `prepend`
        # are singleton-side and `extend` reaches the singleton's own singleton, which nothing names.
        def own_mixin_effects(kind, side, current_class, in_singleton)
          return [] if in_singleton && kind == :extend

          [[current_class, in_singleton ? :extend : side]]
        end

        # A receiver that is not `self` reshapes the class it names, or the singleton of `singleton_class`. Any
        # other receiver is an object of its own (`ids.prepend(1)`, `obj.extend(Decorator)`) and reshapes none of
        # the enclosing class's ancestry — except in a `self.included(base)`-style hook, where `base` IS the
        # class that includes the enclosing module and a call on it taints both sides of the enclosing class.
        def receiver_mixin_effects(node, side, qualified_prefix, current_class, accumulator)
          receiver = node.receiver
          return [[current_class, :extend]] if singleton_class_receiver?(receiver)

          owner = prepend_call_receiver(node, qualified_prefix)
          return [[owner, side]] if owner
          return [] unless hook_receiver?(receiver, accumulator)

          [[current_class, :include], [current_class, :extend]]
        end

        HOOK_DEFS = %i[included extended prepended inherited].freeze
        MIXIN_EVAL_CALLS = %i[class_eval module_eval class_exec module_exec instance_eval instance_exec].freeze
        private_constant :HOOK_DEFS, :MIXIN_EVAL_CALLS

        # The parameter names of a `def included(base)`-style hook (a hook is written `def self.included`, or
        # `def included` inside `class << self`), else nil.
        def hook_def_params(node)
          return nil unless node.is_a?(Prism::DefNode) && HOOK_DEFS.include?(node.name)

          parameters = node.parameters
          return [] unless parameters

          (parameters.requireds + parameters.optionals).filter_map do |parameter|
            parameter.name if parameter.respond_to?(:name)
          end
        end

        # Whether `receiver` is a hook parameter, or `singleton_class` / a no-argument call chain off one.
        def hook_receiver?(receiver, accumulator)
          case receiver
          when Prism::LocalVariableReadNode then accumulator.hook_local?(receiver.name)
          when Prism::CallNode
            receiver.arguments.nil? && receiver.receiver && hook_receiver?(receiver.receiver, accumulator)
          else false
          end
        end

        # `base.class_eval { include X }` in a hook, and `opaque.module_eval { include B }` anywhere: the block
        # opens a class this walk cannot name, so its mixin calls record nowhere, yet the enclosing class's
        # ancestry is what the reader was asked about. Taint both sides of the enclosing class. Outside a hook
        # the block is scanned for a mixin call first, so an ordinary `obj.instance_eval { … }` DSL taints nothing.
        def taint_opaque_eval(node, current_class, accumulator)
          return unless current_class && node.block.is_a?(Prism::BlockNode) && MIXIN_EVAL_CALLS.include?(node.name)

          receiver = node.receiver
          return if receiver.nil? || receiver.is_a?(Prism::SelfNode)
          return if Source::ConstantPath.qualified_name_or_nil(receiver)

          hook = hook_receiver?(receiver, accumulator)
          return unless hook || block_mixes_in?(node.block)

          # Issue #2991 — the set is unknown only where the block may mix into the class itself: a hook's `base`, or a
          # receiverless `include` / `prepend` in the block of a receiver other than a `singleton_class`.
          unnamed = hook || (!singleton_class_eval_receiver?(receiver) && block_mixes_into_self?(node.block))
          accumulator.taint(current_class, :include, unnamed: unnamed)
          accumulator.taint(current_class, :extend)
        end

        def block_mixes_in?(node)
          return true if node.is_a?(Prism::CallNode) &&
                         (MIXIN_KINDS.include?(node.name) || ScopeIndexer.mixin_call_view(node))

          found = false
          node.rigor_each_child { |child| found ||= block_mixes_in?(child) }
          found
        end

        # A receiverless or `self.` `include` / `prepend` (or its `send` spelling) anywhere in `node`.
        def block_mixes_into_self?(node)
          if node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
            view = ScopeIndexer.mixin_call_view(node)
            return true if view && INSTANCE_MIXIN_NAMES.include?(view.first)
          end

          found = false
          node.rigor_each_child { |child| found ||= block_mixes_into_self?(child) }
          found
        end

        def singleton_class_eval_receiver?(receiver)
          receiver.is_a?(Prism::CallNode) && receiver.name == :singleton_class
        end

        def singleton_class_receiver?(receiver)
          receiver.is_a?(Prism::CallNode) && receiver.name == :singleton_class && receiver.arguments.nil? &&
            (receiver.receiver.nil? || receiver.receiver.is_a?(Prism::SelfNode))
        end

        # Issue #1123 — the class a `Recv.prepend(M)` call form targets, as the qualified name the prepend
        # table is keyed by, or nil when the receiver names no static class. The receiver is a constant READ
        # at the call site, so it resolves in the `Module.nesting` the call is written in — the same rule (and
        # the same helper) `class_eval` receivers follow: `::B` names the top level wherever it is written, an
        # unqualified `X` is `<nesting entry>::X` for the innermost entry the FILE declares, and the
        # as-written name stands when no rung declares it. A receiver that names no project class keys a table
        # entry nothing reads, which is the same silence as not recording it at all.
        def prepend_call_receiver(node, lexical_prefix)
          receiver = node.receiver
          return nil if receiver.is_a?(Prism::SelfNode)

          rendered = Source::ConstantPath.qualified_name_or_nil(receiver)
          return nil if rendered.nil?
          return rendered if Source::ConstantPath.rooted?(receiver) || lexical_prefix.empty?

          DeclarationWalk::Rules.eval_constant_receiver_prefix(node, receiver, rendered, lexical_prefix).join("::")
        end

        # The owner a meta-new write gives the block for the MIXIN tables — every definite
        # write form, including `||=` and path-or-write: an `||=` block still runs on the
        # class the write names when it runs, so `K ||= Class.new { include I }` mixes I
        # into K exactly the way its `def`s land `K#m`. The census keeps the narrower
        # {ConstantTables.meta_new_block_owner} / {ConstantTables.meta_new_owner_under_cref} pair because its `||=`
        # rows are unpublished (#963). Nil where the write names nothing below an
        # unnameable cref.
        def meta_new_mixin_owner(node, qualified_prefix, singleton_cref, self_base = nil)
          return nil if singleton_cref && !DeclarationWalk::Rules.meta_new_path_target_nameable?(node, self_base)

          DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, self_base)&.join("::")
        end

        private_class_method :hook_parameter_receiver?, :taint_computed_hook_send, :computed_send_name,
                             :local_send_names, :collect_local_send_names, :iterated_element_names,
                             :local_send_name_literal, :iterated_element_source, :iterated_first_parameter?,
                             :iterated_receiver_elements, :constant_array_elements, :constant_write_nodes,
                             :constant_binding?, :iterated_element_children, :literal_send_name, :local_binding?,
                             :own_mixin_effects, :receiver_mixin_effects, :hook_receiver?, :block_mixes_in?,
                             :block_mixes_into_self?, :singleton_class_eval_receiver?, :singleton_class_receiver?
      end
    end
  end
end
