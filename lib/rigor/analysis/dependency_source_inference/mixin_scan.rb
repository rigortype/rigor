# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../../inference/refine_census"
require_relative "../../inference/scope_indexer"

module Rigor
  module Analysis
    module DependencySourceInference
      # Issue #1814 — what one gem file can do to a module that the refinement table and the declaration walk do not
      # show, read in one pass.
      #
      # **Mixins.** `using M` puts in effect the refinements of every module `M` includes or prepends (CRuby's
      # `using_module_recursive` walks the module's ancestors; Ruby 4.0.5 prints `:inc` for `module Inc; refine(String)
      # { def foo = :inc }; end; module M; include Inc; end; using M; "x".foo`), and the gem table has no mixin edges.
      # {#site} is true when the file calls `include`, `prepend`, `append_features` or `prepend_features` on an explicit
      # receiver, or on `self` outside a class body (a class's own `include` mixes into a class, which `using` rejects;
      # a block may run under any `self`, so it does not keep the class; a `def` under `class << self` runs with the
      # `self` of the enclosing body, so it keeps the class only when that is one), when it holds an `:include`,
      # `:prepend`, `:append_features` or `:prepend_features` Symbol (`send(:include, X)`, `method(:include)`), or an
      # eval, `send` or method-naming call with a String that holds one of those words. {#targets} names the modules
      # such a call mixes into when it says so with a constant, by every spelling the lexical position can denote (the
      # receiver of an explicit `include` / `prepend` / `send(:include, …)` / eval, the argument of an
      # `append_features` / `prepend_features`): a gem that mixes into a module another gem declares is not read in
      # full, and the module it mixes into is not either ({Index#fully_read_module?}). A feature call in a class body
      # is not a site (`Class` undefines `append_features`), and neither is the body of `class << self`, which mixes
      # into the singleton class.
      #
      # **Constants the gem cannot account for.** A constant the gem neither declares nor Ruby core or stdlib declares,
      # in a position that hands the module being defined to code the walk has not read, may change its refinements:
      # `extend Refiner` (a helper whose method calls `refine`, `module Refiner; def refines_string(n) = refine(String)
      # { define_method(n) { :ok } }; end; module Dslg; extend Refiner; refines_string :foo; end`, then `using Dslg`
      # refines String on Ruby 4.0.5), an `include` in the body of `class << self` of a module (the same `extend` by
      # another spelling), `Plugin.install(self)` (a foreign method that includes into the module it is given),
      # `Refiner.send(:extend_object, self)`, `Registry.configure { … }`, and a refine target or a prefix of one.
      # {#foreign} lists the candidate names of each such constant; {#foreign_targets} those of a refine target, which
      # an alias the reader decides is class-unknown accounts for as well. The positions count in a module context: a
      # module body, a method or `class << self` of a module, a block whose call keeps `self` there (an eval-family
      # call, `Module.new`, or any block of a module context), and an explicit constant receiver anywhere. An argument
      # that is no constant (`extend(*mods)`) is unaccountable and sets {#site}. The walker drops the names its own
      # files declare, and the reader the ones Ruby core or stdlib declares or another read-in-full gem does
      # ({Index#fully_read_module?}). `extend self`, `include Comparable` in a class, and a call on a core constant add
      # nothing.
      #
      # **Constant writes.** {#writes} lists the constants the file writes, as `[qualified name or nil, last segment]`
      # pairs: an assignment, a path write, an operator write, a multiple assignment, a `const_set` with a literal name.
      # The qualified name is nil where the lexical position does not give one.
      class MixinScan
        MIXIN_CALLS = Set[:include, :prepend].freeze
        # The calls whose argument, not receiver, is the module mixed into.
        FEATURE_CALLS = Set[:append_features, :prepend_features].freeze
        MIXIN_SYMBOLS = Set["include", "prepend", "append_features", "prepend_features"].freeze
        MIXIN_WORD = /\b(?:include|prepend|append_features|prepend_features)\b/
        # The calls on a constant that can hand it the module they run in: it is the receiver of a `send`, an eval, an
        # `extend_object` or a `define_method`.
        HANDOFF_CALLS = (Inference::RefineCensus::SEND_CALLS | Inference::RefineCensus::SELF_EVAL_CALLS |
                         Set[:extend_object, :define_method, :define_singleton_method]).freeze
        # The constant-write nodes whose target is a bare name, and the ones whose target is a path.
        BARE_WRITES = [
          Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
          Prism::ConstantOperatorWriteNode, Prism::ConstantTargetNode
        ].freeze
        PATH_WRITES = [
          Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode,
          Prism::ConstantPathOperatorWriteNode
        ].freeze
        private_constant :MIXIN_CALLS, :FEATURE_CALLS, :MIXIN_SYMBOLS, :MIXIN_WORD, :HANDOFF_CALLS, :BARE_WRITES,
                         :PATH_WRITES

        # `prefix` is the lexical nesting; `in_class` whether `self` is a class here and `def_in_class` whether it is in
        # a method defined here (a method in `class << self` runs on the object whose singleton it is, not on the
        # singleton class); `modctx` whether `self` may be a module here and `def_modctx` whether it may be in a method
        # defined here; `sing` whether this is the body of `class << self` of a module; `eval_targets` the candidate
        # names of the constant a `*_eval` call whose block this is runs on.
        Scope = Data.define(:prefix, :in_class, :def_in_class, :modctx, :def_modctx, :sing, :eval_targets)
        private_constant :Scope

        attr_reader :site, :targets, :foreign, :foreign_targets, :writes

        def self.scan(root)
          scan = new
          scan.send(:walk, root, Scope.new([], false, false, false, false, false, []))
          scan
        end

        def initialize
          @site = false
          @targets = Set.new
          @foreign = []
          @foreign_targets = []
          @writes = []
        end

        private

        def walk(node, scope)
          case node
          when Prism::ClassNode, Prism::ModuleNode then scope = enter(node, scope)
          when Prism::SingletonClassNode then scope = singleton(node, scope)
          when Prism::DefNode
            scope = scope.with(in_class: scope.def_in_class, modctx: scope.def_modctx, sing: false, eval_targets: [])
          # A block may run under any `self` (`Module.new { include X }`, `M.module_eval { include X }`).
          when Prism::BlockNode, Prism::LambdaNode
            scope = scope.with(in_class: false, def_in_class: false, sing: false)
          when Prism::SymbolNode then return @site ||= MIXIN_SYMBOLS.include?(node.unescaped)
          when Prism::CallNode then return walk_call(node, scope)
          when *BARE_WRITES, *PATH_WRITES, Prism::ConstantPathTargetNode then @writes << write_entry(node, scope)
          end
          node.rigor_each_child { |child| walk(child, scope) }
        end

        def enter(node, scope)
          prefix = Source::ConstantPath.declaration_prefix(scope.prefix, node.constant_path) || scope.prefix
          klass = node.is_a?(Prism::ClassNode)
          Scope.new(prefix, klass, klass, !klass, !klass, false, [])
        end

        # The body of `class << self` mixes into the singleton class, which `using` never reads; a method defined there
        # runs with the `self` of the enclosing body, so a module's does not keep the class (`def enable! =
        # include(Inc)` under `class << self` in a module mixes into the module). `class << expr` is an object the
        # scan cannot name; it may be a module.
        def singleton(node, scope)
          of_self = node.expression.is_a?(Prism::SelfNode)
          Scope.new(scope.prefix, true, of_self && scope.in_class, !of_self || scope.modctx, !of_self || scope.modctx,
                    of_self && scope.modctx, [])
        end

        def walk_call(node, scope)
          inspect_call(node, scope)
          block = node.block
          block_scope = block && block_scope_of(node, scope)
          node.rigor_each_child { |child| walk(child, block && child.equal?(block) ? block_scope : scope) }
        end

        # An eval-family block runs on its receiver, and a `Module.new` block on a module; any other block keeps the
        # module context it is written in.
        def block_scope_of(node, scope)
          modctx = scope.modctx || module_block?(node)
          scope.with(modctx: modctx, def_modctx: modctx, eval_targets: eval_targets_of(node, scope))
        end

        def module_block?(node)
          Inference::RefineCensus::SELF_EVAL_CALLS.include?(node.name) ||
            (node.name == :new && constant_named?(node.receiver, "Module"))
        end

        def constant_named?(node, name) = constant?(node) && Source::ConstantPath.qualified_name(node) == name

        def write_entry(node, scope)
          case node
          when *BARE_WRITES then [(scope.prefix + [node.name.to_s]).join("::"), node.name.to_s]
          when *PATH_WRITES then [nil, node.target.name.to_s]
          else [nil, node.name.to_s]
          end
        end

        def inspect_call(node, scope)
          note_const_set(node)
          if MIXIN_CALLS.include?(node.name) || FEATURE_CALLS.include?(node.name)
            inspect_mixin_call(node, scope)
          elsif node.name == :extend
            note_extend(node, scope)
          elsif Inference::RefineCensus.string_literal_call?(node) && mixin_argument?(node)
            @site = true
            note_receiver(node, scope)
          end
          note_handoff(node, scope)
          note_refine_target(node, scope)
        end

        def note_const_set(node)
          name = node.name == :const_set && node.arguments&.arguments&.first
          @writes << [nil, name.unescaped] if name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)
        end

        def inspect_mixin_call(node, scope)
          @site = true if !scope.in_class || !Inference::RefineCensus.self_call?(node)
          if FEATURE_CALLS.include?(node.name)
            (node.arguments&.arguments || []).each { |argument| note_constant(argument, scope) }
          else
            note_receiver(node, scope)
            note_mixin_arguments(node, scope) if scope.sing && Inference::RefineCensus.self_call?(node)
          end
        end

        # `extend X` on `self` (in a module context) or on a constant.
        def note_extend(node, scope)
          return unless explicit_constant?(node) || (scope.modctx && Inference::RefineCensus.self_call?(node))

          note_mixin_arguments(node, scope)
        end

        def explicit_constant?(node) = !Inference::RefineCensus.self_call?(node) && constant?(node.receiver)

        # The modules handed to a call that gives them to the module in effect (`extend Refiner`, `include Refiner` in
        # `class << self`): a constant is foreign unless it is accounted for, any other argument cannot be.
        def note_mixin_arguments(node, scope)
          (node.arguments&.arguments || []).each do |argument|
            next if argument.is_a?(Prism::SelfNode)

            constant?(argument) ? @foreign << candidates(argument, scope) : @site = true
          end
        end

        # A call on a constant that passes the module in effect to it (`Plugin.install(self)`), takes a block
        # (`Registry.configure { … }`) or runs on it (`Refiner.send(:extend_object, self)`).
        def note_handoff(node, scope)
          return unless scope.modctx

          root = constant_root(node.receiver)
          return if root.nil? || !(HANDOFF_CALLS.include?(node.name) || passes_self?(node) || node.block)

          @foreign << candidates(root, scope)
        end

        def constant_root(node)
          node = node.receiver while node.is_a?(Prism::CallNode)
          node if constant?(node)
        end

        def passes_self?(node)
          (node.arguments&.arguments || []).any? do |argument|
            argument.is_a?(Prism::SelfNode) ||
              (argument.is_a?(Prism::KeywordHashNode) && argument.elements.any? { |pair| self_value?(pair) })
          end
        end

        def self_value?(pair) = pair.is_a?(Prism::AssocNode) && pair.value.is_a?(Prism::SelfNode)

        # `refine X { … }` in a module context: the class refined, which an alias or a class no walked gem declares may
        # keep from matching a receiver.
        def note_refine_target(node, scope)
          return unless node.name == :refine && scope.modctx && Inference::RefineCensus.self_call?(node)

          target = node.arguments&.arguments&.first
          @foreign_targets << candidates(target, scope) if constant?(target)
        end

        # `Base.send(:include, X)`: the receiver is the module mixed into.
        def mixin_argument?(node)
          (node.arguments&.arguments || []).any? { |argument| mixin_string?(argument) || mixin_symbol?(argument) }
        end

        def mixin_symbol?(node) = node.is_a?(Prism::SymbolNode) && MIXIN_SYMBOLS.include?(node.unescaped)

        # As {Inference::RefineCensus.refine_string?}: a String literal (or a heredoc's literal part) holding a mixin
        # word, read as bytes.
        def mixin_string?(node)
          case node
          when Prism::StringNode then MIXIN_WORD.match?(node.unescaped.b)
          when Prism::InterpolatedStringNode then node.parts.any? { |part| mixin_string?(part) }
          else false
          end
        end

        # The module a mixin call mixes into: its constant receiver, else the constant a `*_eval` block runs on.
        def note_receiver(node, scope)
          if Inference::RefineCensus.self_call?(node)
            @targets.merge(scope.eval_targets)
          else
            note_constant(node.receiver, scope)
          end
        end

        def note_constant(node, scope) = @targets.merge(candidates(node, scope))

        def candidates(node, scope)
          constant?(node) ? Inference::ScopeIndexer.constant_receiver_candidates(node, scope.prefix) : []
        end

        def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

        def eval_targets_of(node, scope)
          return scope.eval_targets unless Inference::RefineCensus::SELF_EVAL_CALLS.include?(node.name)
          return scope.eval_targets if Inference::RefineCensus.self_call?(node)

          candidates(node.receiver, scope)
        end
      end
    end
  end
end
