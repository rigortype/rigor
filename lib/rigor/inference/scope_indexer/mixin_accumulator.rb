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
      # an opaque eval whose block mixes into its own `self`. An unrecorded call whose arguments are all constants
      # (`self.include M`, a receiverless `send(:include, M)`, a hook's `base.include M`) lists those names after
      # {WILDCARD} instead: the set is known, but no table records it under the owner.
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
          @program = nil
        end

        # Marks the file's own top-level statements: a receiverless `include` among them is `main.include`,
        # which mixes into `Object` (issue #1697).
        def program_body(body)
          return unless body.is_a?(Prism::StatementsNode)

          @program = Set.new.compare_by_identity.merge(body.body)
        end

        def program_statement?(node)
          !@program.nil? && @program.include?(node)
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
        # nothing the walk could record, which leaves the recorded names' neighbours unknown.
        def note(node, owner, side, targets, complete:)
          return taint(owner, side, unnamed: side == :include) unless complete
          return if node.receiver.nil? && direct?(node)

          add(owner, side, targets)
        end

        # Names `owner`'s `side` as having no known order; `unnamed` also as holding a module no name spells.
        # `names` are the constants an unrecorded call mixed in (`self.include M`, #2991), listed after {WILDCARD}
        # so a reader can ask them for a method the tables do not record under the owner.
        def taint(owner, side, unnamed: false, names: nil)
          add(owner, side, unnamed ? UNNAMED_LIST : WILDCARD_LIST)
          add(owner, side, names) if names && !names.empty?
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
    end
  end
end
