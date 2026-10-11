# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../../inference/refine_census"
require_relative "../../inference/scope_indexer"

module Rigor
  module Analysis
    module DependencySourceInference
      # Issue #1814 — can one gem file change which modules a module includes or prepends? `using M` puts in effect the
      # refinements of every module `M` includes or prepends (CRuby's `using_module_recursive` walks the module's
      # ancestors; Ruby 4.0.5 prints `:inc` for `module Inc; refine(String) { def foo = :inc }; end; module M; include
      # Inc; end; using M; "x".foo`), and the gem table has no mixin edges. {#site} is true when the file calls
      # `include` or `prepend` on an explicit receiver, or on `self` outside a class body (a class's own `include`
      # mixes into a class, which `using` rejects; a block may run under any `self`, so it does not keep the class),
      # when it holds an `:include`, `:prepend`, `:append_features` or `:prepend_features` Symbol (`send(:include, X)`,
      # `method(:include)`), or an eval, `send` or method-naming call with a String that holds one of those words.
      #
      # {#targets} names the modules such a call mixes into when it says so with a constant: the receiver of an
      # explicit `include` / `prepend` / `send(:include, …)` / eval, the argument of an `append_features` /
      # `prepend_features`, by every spelling the lexical position can denote. A gem that mixes into a module another
      # gem declares is not read in full, and the module it mixes into is not either, whichever gem declared it
      # ({Index#fully_read_module?}).
      #
      # {#extends} lists the modules the file `extend`s outside a class body: each entry holds the candidate names of a
      # constant argument, or nil for an argument that is no constant. A module `extend`ed into a module may call
      # `refine` on the extender (`module Refiner; def refines_string = refine(String) { … }; end; module Dslg; extend
      # Refiner; refines_string; end`, then `using Dslg` refines String on Ruby 4.0.5), so the walker reads the
      # extender as not read in full unless the gem declares the extended module, whose `refine` the census then sees.
      # `extend self` and an `extend` in a class body, which cannot be `using`'d, are not listed.
      #
      # {#writes} lists the constants the file writes, as `[qualified name or nil, last segment]` pairs: an assignment,
      # a path write, an operator write, a multiple assignment, a `const_set` with a literal name. The qualified name
      # is nil where the lexical position does not give one.
      class MixinScan
        MIXIN_CALLS = Set[:include, :prepend].freeze
        # The calls whose argument, not receiver, is the module mixed into.
        FEATURE_CALLS = Set[:append_features, :prepend_features].freeze
        MIXIN_SYMBOLS = Set["include", "prepend", "append_features", "prepend_features"].freeze
        MIXIN_WORD = /\b(?:include|prepend|append_features|prepend_features)\b/
        # The constant-write nodes whose target is a bare name, and the ones whose target is a path.
        BARE_WRITES = [
          Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
          Prism::ConstantOperatorWriteNode, Prism::ConstantTargetNode
        ].freeze
        PATH_WRITES = [
          Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode,
          Prism::ConstantPathOperatorWriteNode
        ].freeze
        private_constant :MIXIN_CALLS, :FEATURE_CALLS, :MIXIN_SYMBOLS, :MIXIN_WORD, :BARE_WRITES, :PATH_WRITES

        # `prefix` is the lexical nesting, `in_class` whether `self` is a class here, `def_in_class` whether it is in a
        # method defined here (a method in `class << self` runs on the object whose singleton it is, not on the
        # singleton class), and `eval_targets` the candidate names of the constant a `*_eval` call whose block this is
        # runs on.
        Scope = Struct.new(:prefix, :in_class, :def_in_class, :eval_targets)
        private_constant :Scope

        attr_reader :site, :targets, :extends, :writes

        def self.scan(root)
          scan = new
          scan.send(:walk, root, Scope.new([], false, false, []))
          scan
        end

        def initialize
          @site = false
          @targets = Set.new
          @extends = []
          @writes = []
        end

        private

        def walk(node, scope)
          case node
          when Prism::ClassNode, Prism::ModuleNode then scope = enter(node, scope)
          when Prism::SingletonClassNode then scope = singleton(node, scope)
          when Prism::DefNode then scope = Scope.new(scope.prefix, scope.def_in_class, scope.def_in_class, [])
          # A block may run under any `self` (`Module.new { include X }`, `M.module_eval { include X }`).
          when Prism::BlockNode, Prism::LambdaNode
            scope = Scope.new(scope.prefix, false, false, scope.eval_targets)
          when Prism::SymbolNode then return @site ||= MIXIN_SYMBOLS.include?(node.unescaped)
          when Prism::CallNode then return walk_call(node, scope)
          when *BARE_WRITES, *PATH_WRITES, Prism::ConstantPathTargetNode then note_write(node, scope)
          end
          node.rigor_each_child { |child| walk(child, scope) }
        end

        def enter(node, scope)
          prefix = Source::ConstantPath.declaration_prefix(scope.prefix, node.constant_path) || scope.prefix
          Scope.new(prefix, node.is_a?(Prism::ClassNode), node.is_a?(Prism::ClassNode), [])
        end

        # The body of `class << self` mixes into the singleton class, which `using` never reads; a method defined there
        # runs with the `self` of the enclosing body, so a module's does not keep the class (`def enable! =
        # include(Inc)` under `class << self` in a module mixes into the module). `class << expr` is an object the
        # scan cannot name.
        def singleton(node, scope)
          Scope.new(scope.prefix, true, node.expression.is_a?(Prism::SelfNode) && scope.in_class, [])
        end

        def walk_call(node, scope)
          inspect_call(node, scope)
          block = node.block
          block_scope = block && Scope.new(scope.prefix, scope.in_class, scope.def_in_class,
                                           eval_targets_of(node, scope))
          node.rigor_each_child { |child| walk(child, block && child.equal?(block) ? block_scope : scope) }
        end

        # A bare name is qualified by the lexical prefix; a path write is not (its owner is a value).
        def note_write(node, scope)
          @writes << write_entry(node, scope)
        end

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
        end

        def note_const_set(node)
          name = node.name == :const_set && node.arguments&.arguments&.first
          @writes << [nil, name.unescaped] if name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)
        end

        # `extend X` on `self` or on a constant, outside a class body.
        def note_extend(node, scope)
          return if scope.in_class || !(Inference::RefineCensus.self_call?(node) || constant?(node.receiver))

          (node.arguments&.arguments || []).each do |argument|
            @extends << (constant?(argument) ? candidates(argument, scope) : nil) unless argument.is_a?(Prism::SelfNode)
          end
        end

        def inspect_mixin_call(node, scope)
          @site = true if !scope.in_class || !Inference::RefineCensus.self_call?(node)
          if FEATURE_CALLS.include?(node.name)
            (node.arguments&.arguments || []).each { |argument| note_constant(argument, scope) }
          else
            note_receiver(node, scope)
          end
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
