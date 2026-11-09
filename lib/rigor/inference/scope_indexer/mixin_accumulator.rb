# frozen_string_literal: true

module Rigor
  module Inference
    module ScopeIndexer
      # The accumulator the mixin walks ({ScopeIndexer#mixin_tables}, {ScopeIndexer#extend_tables}) fill: the
      # per-class module lists as before, plus which mixin edges have no position the tables can vouch for
      # (`Scope::DiscoveryIndex#unpositioned_mixins`).
      #
      # The mixin tables store each class's modules in the order the statements that wrote them run, and that
      # order is a fact only for a DIRECT statement of the class's own body (or of its `class << self` body),
      # in a declaration that is itself a direct statement (a top-level statement, or a direct statement of a
      # direct body): `include M` there runs where it is written, unconditionally. An `include` inside a
      # method, a block (`class_eval`, `Class.new`, `included do`), a conditional, or a declaration wrapped in
      # a conditional or a block (`class C; include B; end if X`) runs when that code runs, if it runs at
      # all, and the receiver form (`Base.prepend(M)`) runs wherever it is called from, so the order the
      # tables give such an edge is a guess. The walks record those edges as they always did and name them
      # here, so a reader that depends on ORDER can decline where the order is not known. An edge written
      # both ways is unpositioned: one guessed copy is enough to move the answer.
      #
      # A mixin call the walks CANNOT record (`include helper`, `include(*MODS)`, `send(:include, M)`,
      # `self.include M`, `C.include(M)`, `singleton_class.include M`, `base.extend M` or
      # `base.class_eval { include M }` in a `self.included(base)` hook, a name in an argument list beside one
      # the walk cannot name) still reshapes the ancestry of the class it belongs to, and
      # leaves the edges the tables did record looking positioned. So it taints the whole owner side with the
      # {WILDCARD} name instead: an owner side that lists {WILDCARD} has no known order at all.
      #
      # Issue #2991 — {WILDCARD} says only that the ORDER is unknown: `include M; prepend M`, an edge recorded where its
      # position is not a fact, and an opaque eval whose block mixes nothing into its own `self` all set it while every
      # module is recorded. Where the walk recorded no module under any name, the instance side also lists
      # {UNNAMED}, always beside {WILDCARD}, because its SET of modules is unknown too. That covers an instance-side
      # mixin call it could not record whose argument is not a constant (`include helper`, `include(*MODS)`; a
      # `Module.new { … }` argument keeps its #2975 reading), a name beside one it cannot name (`include M, h`), and
      # an opaque eval whose block mixes into its own `self`, and a hook's `base.include M`. `self.include M` and a
      # receiverless `send(:include, M)` are recorded as a bare `include M` is (#2995). Issue #2994 — the singleton side
      # lists {UNNAMED} the same way for an `extend` (or a `class << self` `include` / `prepend`) it could not record
      # whose arguments include no constant (`extend(*EMODS)`, `extend helper`), and for a name beside one it cannot
      # name (`extend M, h`).
      #
      # The value is `{owner => {include: [names], extend: [names]}}`. `:include` is the instance side
      # (`include` and `prepend`), `:extend` the singleton side (`extend`, and `include` / `prepend` inside
      # `class << self`), so an unknown `extend` never taints a class's instance ancestry.
      #
      # A Hash (owner => lists), so every walk helper that indexes the accumulator keeps working unchanged.
      class MixinAccumulator < Hash
        # The name an owner side lists when a mixin call the walk could not record was written on it.
        WILDCARD = "*"
        # The name an owner side also lists when such a call mixes in a module the walk cannot name (#2991).
        UNNAMED = "?"
        UNNAMED_LIST = [WILDCARD, UNNAMED].freeze
        WILDCARD_LIST = [WILDCARD].freeze
        private_constant :UNNAMED_LIST, :WILDCARD_LIST

        # What {#unpositioned} answers when nothing was noted: one shared frozen table, so the common file
        # allocates none.
        EMPTY = {}.freeze

        DIRECT_STATEMENTS = [Prism::CallNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
        private_constant :DIRECT_STATEMENTS

        def initialize
          super
          @direct = nil
          @unpositioned = nil
          @hook_params = nil
          @body_blocks = nil
          @program_body = nil
          @program = nil
          @class_bodies = nil
          @class_body_calls = nil
          @class_bodies_read = 0
        end

        # Marks the file's own top-level statements: a receiverless `include` among them is `main.include`,
        # which mixes into `Object` (issue #1697).
        def program_body(body)
          return unless body.is_a?(Prism::StatementsNode)

          @program_body = body
        end

        # Whether `node` is a call whose `self` is `main`'s as far as the walk can tell: a top-level statement, or
        # a call reached from one through control flow alone (issue #3007), so a receiverless `include` there is
        # `main.include`. The set is built on the first question, which only a top-level mixin call asks.
        def program_statement?(node)
          return false if @program_body.nil?

          @program ||= MainSelfCalls.collect(@program_body)
          @program.include?(node)
        end

        # Issue #3006 — registers a class or module body (or its `class << self` body), whose calls
        # {#class_body_scope} answers for.
        def class_body(body)
          (@class_bodies ||= []) << body if body
        end

        # The node whose locals a call written in a registered class body reads — the body itself, or the `def self.`
        # it sits in — or nil when the call is not one whose `self` is that body's class as far as {MainSelfCalls}
        # can tell (an instance `def`, a block that may rebind `self`, a nested declaration). Built on the first
        # question, which only a computed-name `send` asks, and extended with the bodies registered since.
        def class_body_scope(node)
          return nil if @class_bodies.nil?

          @class_body_calls ||= {}.compare_by_identity
          while @class_bodies_read < @class_bodies.size
            @class_body_calls.merge!(MainSelfCalls.collect(@class_bodies[@class_bodies_read], instance_defs: false))
            @class_bodies_read += 1
          end
          @class_body_calls[node]
        end

        # Marks the statements of a body whose own position is a fact — the calls and declarations in them
        # are the only ones whose position is. The caller marks a declaration's body only when the
        # declaration was itself marked (or is the file's top level).
        def direct_body(body)
          return unless body.is_a?(Prism::StatementsNode)

          body.body.each do |statement|
            next unless DIRECT_STATEMENTS.any? { |kind| statement.is_a?(kind) }

            (@direct ||= Set.new.compare_by_identity) << statement
          end
        end

        # Marks the block-carrying calls that are statements of a class or module body, whatever that declaration
        # sits in: the only blocks whose `self` the extends walk takes to be the body's own (#1592).
        def body_statements(body)
          return unless body.is_a?(Prism::StatementsNode)

          body.body.each do |statement|
            if statement.is_a?(Prism::CallNode) && statement.block
              (@body_blocks ||= Set.new.compare_by_identity) << statement
            end
          end
        end

        def body_block?(node)
          !@body_blocks.nil? && @body_blocks.include?(node)
        end

        # Runs the block with the parameters of a `self.included(base)`-style hook in scope: a mixin call on
        # one of them reshapes the class that reached the hook, which this walk cannot name.
        def with_hook_params(names)
          saved = @hook_params
          @hook_params = saved ? saved + names : names
          yield
        ensure
          @hook_params = saved
        end

        def hook_local?(name)
          !@hook_params.nil? && @hook_params.include?(name)
        end

        def direct?(node)
          !@direct.nil? && @direct.include?(node)
        end

        # Notes the edges `node` recorded for `owner` on `side`. `complete` is false when an argument named
        # nothing the walk could record, which leaves the recorded names' neighbours unknown. `positioned` says a
        # receiver-form call runs where it is written, as a receiverless one does (`singleton_class.prepend P`, #2998).
        def note(node, owner, side, targets, complete:, positioned: false)
          return taint(owner, side, unnamed: true) unless complete
          return if (positioned || node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) && direct?(node)

          add(owner, side, targets)
        end

        # Names `owner`'s `side` as having no known order; `unnamed` also as holding a module no name spells.
        def taint(owner, side, unnamed: false)
          add(owner, side, unnamed ? UNNAMED_LIST : WILDCARD_LIST)
        end

        # `{owner => {side => [names]}}`, frozen, each list de-duplicated.
        def unpositioned
          return EMPTY if @unpositioned.nil?

          @unpositioned.transform_values do |sides|
            sides.transform_values { |names| names.uniq.freeze }.freeze
          end.freeze
        end

        private

        def add(owner, side, names)
          ((@unpositioned ||= {})[owner] ||= {})[side] = ((@unpositioned[owner][side] || []) + names)
        end
      end

      # Issue #3007 — the calls whose `self` is `main` as far as the mixin walk can tell: the file's top-level
      # statements, and the calls reached from them through control flow (`if`, `unless`, `case`, `begin`, `rescue`, a
      # loop, `&&` / `||`) or a value position (an assignment's value, a call's receiver or argument, an array literal),
      # or through the body of a top-level `def` or `def self.`, whose `include` the walk reads as ADR-119 WD7 reads one
      # in a method body: a member of the set with no position. A block is entered only when it is a core iterator's
      # that keeps `self` ({SELF_KEEPING_ITERATORS}) on a literal receiver, or a receiverless `loop` / `tap` / `then`.
      # Any other block or lambda is not: its `self` may not be `main` (a `describe do … end` or `class_exec` block
      # rebinds it), and neither is a declaration, `class << self` or a `def` on another receiver, whose `self` is not
      # `main`. Recording more here can only silence: these edges feed no typing (`Inference::ObjectMixins`).
      module MainSelfCalls
        CONTROL_FLOW = [
          Prism::StatementsNode, Prism::BeginNode, Prism::RescueNode, Prism::ElseNode, Prism::EnsureNode,
          Prism::IfNode, Prism::UnlessNode, Prism::CaseNode, Prism::CaseMatchNode, Prism::WhenNode, Prism::InNode,
          Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::ParenthesesNode, Prism::AndNode, Prism::OrNode,
          Prism::RescueModifierNode,
          Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::GlobalVariableWriteNode,
          Prism::ConstantWriteNode, Prism::MultiWriteNode, Prism::ArgumentsNode, Prism::ArrayNode
        ].freeze
        # Core iterators whose block runs with the caller's `self`, entered on a literal receiver.
        SELF_KEEPING_ITERATORS = %i[each each_with_index each_with_object map times upto downto tap then loop].freeze
        # The iterators entered without a receiver: `Kernel#loop`, and `tap` / `then` on `main` itself.
        RECEIVERLESS_ITERATORS = %i[tap then loop].freeze
        LITERAL_RECEIVERS = [Prism::ArrayNode, Prism::RangeNode, Prism::IntegerNode].freeze
        private_constant :CONTROL_FLOW, :SELF_KEEPING_ITERATORS, :RECEIVERLESS_ITERATORS, :LITERAL_RECEIVERS

        module_function

        # `{call => scope}`: each call and the node whose locals it reads, `body` or the `def` it sits in. Issue #3006 —
        # a class body's calls are collected the same way with `instance_defs: false`: an instance `def`'s `self` is
        # an instance, not the class, while a `def self.`'s is the class, and every block is entered.
        def collect(body, instance_defs: true)
          calls = {}.compare_by_identity
          visit(body, calls, body, instance_defs)
          calls
        end

        def visit(node, calls, scope, instance_defs)
          case node
          when Prism::CallNode
            calls[node] = scope
            visit(node.receiver, calls, scope, instance_defs)
            visit(node.arguments, calls, scope, instance_defs)
            entered = instance_defs ? self_keeping_block?(node) : any_block?(node)
            visit(node.block.body, calls, scope, instance_defs) if entered
          when Prism::DefNode
            visit(node.body, calls, node, instance_defs) if (instance_defs && node.receiver.nil?) ||
                                                            node.receiver.is_a?(Prism::SelfNode)
          when *CONTROL_FLOW
            node.compact_child_nodes.each { |child| visit(child, calls, scope, instance_defs) }
          end
        end
        private_class_method :visit

        # Issue #3006 — a class body's calls include those in any block written there (`KINDS.each { … }`, a concern's
        # `included do … end`): a computed `send` in one may mix into the class, or into what the block's `self` is.
        def any_block?(call)
          call.block.is_a?(Prism::BlockNode)
        end
        private_class_method :any_block?

        def self_keeping_block?(call)
          return false unless call.block.is_a?(Prism::BlockNode) && SELF_KEEPING_ITERATORS.include?(call.name)
          return RECEIVERLESS_ITERATORS.include?(call.name) if call.receiver.nil?

          LITERAL_RECEIVERS.any? { |kind| literal(call.receiver).is_a?(kind) }
        end
        private_class_method :self_keeping_block?

        # `(1..2)` is a range literal in parentheses.
        def literal(receiver)
          return receiver unless receiver.is_a?(Prism::ParenthesesNode) && receiver.body.is_a?(Prism::StatementsNode)

          body = receiver.body.body
          body.size == 1 ? body.first : receiver
        end
        private_class_method :literal
      end
    end
  end
end
