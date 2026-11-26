# frozen_string_literal: true

require "prism"

require_relative "../../type"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../declaration_walk/rules"
require_relative "class_declarations"
require_relative "factory_call_resolver"

module Rigor
  module Inference
    module ScopeIndexer
      # The declaration artifacts of one file, moved out of `scope_indexer.rb` whole (ADR-116 WD9, #3400): the
      # identity table that types the outermost path node of each `class` / `module` header as the singleton of the
      # class it declares, and the classes the file declares by qualified name, a constant write that creates a class
      # among them. {.build_declaration_artifacts} is the entry: `ScopeIndexer.index` calls it first, with the names
      # the project declares, and {PreEvalConstants} calls it with none. The other five functions are private: the
      # file's share of the compact-header re-anchoring (#722), the walk, and its three arms.
      #
      # It asks {DeclarationWalk::Rules} for each declaration context, {ClassDeclarations} for the file's compact
      # headers and {FactoryCallResolver} for the factory call a constant write unwinds to. It calls three functions
      # left in `scope_indexer.rb`, the cross-file fold's, at one site each: `ScopeIndexer.compact_header_renames`
      # (the compact headers the project's names re-anchor), `ScopeIndexer.rename_compact_name` (the name one has
      # under those) and `ScopeIndexer.synthesize_namespace_prefixes` (the namespaces a compact name implies, #528).
      # One constant moved with it, the one only it read: {EMPTY_RENAMES}, public as it was. It reads
      # `ScopeIndexer::EMPTY_PREFIX` and `RECEIVER_EVAL_CALLS` lexically, as {NodePropagation} reads the indexer's
      # constants: other rows of `scope_indexer.rb` and other modules read each.
      #
      # `scope_indexer.rb` requires this file, and this file does not require it back. It requires the file of what
      # else it names. So the file loads alone, and until `scope_indexer.rb` has loaded the entry answers for no
      # program: the last thing it does is call `ScopeIndexer.synthesize_namespace_prefixes`, a `NoMethodError`.
      module DeclarationArtifacts
        module_function

        # The no-op re-anchoring table (#722 residue 2): shared so the overwhelmingly common
        # nothing-to-re-anchor walk allocates none.
        EMPTY_RENAMES = {}.freeze

        # Walks the program once for `Prism::ModuleNode` and `Prism::ClassNode`, recording the `Singleton[<qualified>]`
        # type for the outermost `constant_path` node of each declaration. Inner segments of a `class Foo::Bar::Baz`
        # path remain real references (resolved through the ordinary lexical walk), so we annotate ONLY the topmost path
        # node. Nested declarations contribute their fully qualified path: `class A::B; class C; ...` produces `A::B`
        # for the outer and `A::B::C` for the inner.
        # @param declared_names — the project's RAW declared-class names, the oracle
        #   {ScopeIndexer.compact_header_renames} adjudicates this file's compact headers against.
        def build_declaration_artifacts(root, declared_names = nil)
          identity_table = {}.compare_by_identity
          discovered = {}
          record_declarations(root, [], identity_table, discovered,
                              file_compact_header_renames(root, declared_names))
          [identity_table.freeze, ScopeIndexer.synthesize_namespace_prefixes(discovered).freeze]
        end

        # Issue #722 residue 2 — this file's share of the fold's re-anchoring, adjudicated against the project
        # names the fold has already settled. Empty (so the per-node answer stands) whenever the caller has no
        # project table to consult: a `Scope.empty` probe sees one file and cannot know what else declares
        # `Wrap::Outer`, and guessing there is the false positive the whole rule is bounded to avoid.
        def file_compact_header_renames(root, declared_names)
          return EMPTY_RENAMES if declared_names.nil? || declared_names.empty?

          compacts = {}
          ClassDeclarations.collect_class_decls(root, [], {}, compacts)
          return EMPTY_RENAMES if compacts.empty?

          ScopeIndexer.compact_header_renames(compacts, declared_names)
        end

        # `self_prefix` names a REBOUND self for `self::`-anchored declarations — a meta-new
        # block's named class, or `[]` for a self nothing names. nil leaves `self` lexical.
        def record_declarations(node, qualified_prefix, identity_table, discovered, renames = EMPTY_RENAMES,
                                self_prefix = nil, singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ModuleNode, Prism::ClassNode
            return if record_class_or_module?(node, qualified_prefix, identity_table, discovered, renames,
                                              self_prefix, singleton_cref: singleton_cref)
          when Prism::SingletonClassNode
            # The expression evaluates in the enclosing cref; the body's cref is unnameable —
            # and `self` below it is the singleton class, which `self::` headers decline on.
            record_declarations(node.expression, qualified_prefix, identity_table, discovered, renames,
                                self_prefix, singleton_cref: singleton_cref)
            if node.body
              record_declarations(node.body, qualified_prefix, identity_table, discovered, renames,
                                  EMPTY_PREFIX, singleton_cref: true)
            end
            return
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathOrWriteNode
            return if record_meta_new_constant?(node, qualified_prefix, identity_table, discovered,
                                                self_prefix, singleton_cref: singleton_cref)
          when Prism::CallNode
            return if record_eval_declarations?(node, qualified_prefix, identity_table, discovered,
                                                renames, self_prefix, singleton_cref)
          end

          node.rigor_each_child do |child|
            record_declarations(child, qualified_prefix, identity_table, discovered, renames,
                                self_prefix, singleton_cref: singleton_cref)
          end
        end

        def record_class_or_module?(node, qualified_prefix, identity_table, discovered, renames = EMPTY_RENAMES,
                                    self_prefix = nil, singleton_cref: false)
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path, self_prefix)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          return false unless child_prefix

          if self_decl&.empty? ||
             (singleton_cref && !DeclarationWalk::Rules.decl_nameable_under_cref?(node) && !self_decl&.any?)
            # `class D` below `class <<` opens `#<singleton>::D` — a real class nothing can
            # name — so nothing is registered; the body still walks so nameable headers
            # below it re-anchor at a real cref. The same holds for `class self::D` where
            # `self` is opaque (`REGISTRY.first.class_eval { … }`): `self_decl` is `[]`.
            if node.body
              record_declarations(node.body, [], identity_table, discovered, renames,
                                  nil, singleton_cref: true)
            end
            return true
          end

          # Issue #722 residue 2 — the per-file twin of the fold's re-anchoring. The file's own declaration
          # table merges OVER the project seed, so without this a compact header would re-publish the key the
          # fold already moved and a reference written INSIDE the enclosing namespace would resolve to it
          # again. The adjudication itself is the project's: `renames` arrives already settled.
          full = ScopeIndexer.rename_compact_name(renames, child_prefix.join("::"))
          child_prefix = full.split("::")
          singleton = Type::Combinator.singleton_of(full)
          identity_table[node.constant_path] = singleton
          discovered[full] = singleton
          record_declarations(node.body, child_prefix, identity_table, discovered, renames) if node.body
          true
        end

        # Recognises class-creating meta calls at constant-write rvalue position and registers `Const` (qualified by the
        # surrounding class/module path) as a discovered class. `Const.new(...)` then resolves to a fresh
        # `Nominal[Const]` via `meta_new`, instead of the un-narrowed `Dynamic[top]` returned by the default `Class#new`
        # envelope.
        #
        # The recognised meta forms are {DeclarationWalk::Rules.meta_new_constant_rvalue?}'s four —
        # `Data.define`, `Struct.new`, `Class.new`, `Module.new` — plus the
        # `Class.new(<factory>)` wrapper {FactoryCallResolver.resolve_meta_factory_call} unwraps:
        #
        # - `Const = Data.define(*Symbol) [do ... end]`
        # - `Const = Struct.new(*Symbol [, keyword_init: ...]) [do ... end]`
        # - `Const = Class.new [(super)] [do ... end]` / `Const = Module.new [do ... end]`
        #
        # Issue [#703](https://github.com/rigortype/rigor/issues/703) — and their `Holder::Const = …` spellings, which
        # name a class just as unconditionally. Until this arm took them, `Holder::Thing.new(1)` fell to the default
        # `Class#new` envelope on `singleton(Struct)` and handed every reader a bare `Struct`.
        #
        # The block body, if present, is recursed into so any nested class/module declarations in the override block
        # (rare but legal) still feed the discovered table.
        def record_meta_new_constant?(node, qualified_prefix, identity_table, discovered,
                                      self_prefix = nil, singleton_cref: false)
          rvalue = DeclarationWalk::Rules.meta_new_rvalue(node)
          factory_call = rvalue.is_a?(Prism::CallNode) &&
                         (FactoryCallResolver.resolve_meta_factory_call(rvalue) ||
                          DeclarationWalk::Rules.meta_new_constant_rvalue?(rvalue))
          return false unless factory_call

          child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, self_prefix)
          return false if child_prefix.nil?
          # A bare write below `class <<` lands on the singleton's own constant table —
          # `#<singleton>::K` names nothing — so the discovered-class entry is declined.
          # A path write (`::K`, `C::K`, `Foo::F`) resolves its base lexically and stays nameable.
          return false if singleton_cref && !DeclarationWalk::Rules.meta_new_path_target_nameable?(node, self_prefix)

          full = child_prefix.join("::")
          discovered[full] = Type::Combinator.singleton_of(full) unless full.empty?
          # The rvalue's receiver and arguments evaluate BEFORE the write lands — under the
          # enclosing self — while the block runs with `self` rebound to the class the write
          # names (`K = Class.new(class self::Y; self; end)` opens `C::Y`, not `C::K::Y`).
          [rvalue.receiver, *rvalue.arguments&.arguments.to_a].compact.each do |part|
            record_declarations(part, qualified_prefix, identity_table, discovered,
                                EMPTY_RENAMES, self_prefix, singleton_cref: singleton_cref)
          end
          if (body = rvalue.block.is_a?(Prism::BlockNode) && rvalue.block.body)
            record_declarations(body, qualified_prefix, identity_table, discovered,
                                EMPTY_RENAMES, child_prefix, singleton_cref: singleton_cref)
          end
          true
        end

        # The eval-family arm of {.record_declarations}: the receiver and arguments keep the
        # enclosing self; the block's `self` is the receiver for `self::` headers —
        # `Foo.class_eval { class self::Inner }` opens `Foo::Inner`, never `M::Inner` — while
        # `Module.nesting`, and so every bare header, stays lexical. `instance_eval` belongs
        # too: it rebinds `self` for constant anchoring even though its `def`s bind on the
        # receiver's singleton.
        def record_eval_declarations?(node, qualified_prefix, identity_table, discovered, renames,
                                      self_prefix, singleton_cref)
          return false unless node.block.is_a?(Prism::BlockNode) &&
                              RECEIVER_EVAL_CALLS.include?(node.name)

          [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
            record_declarations(part, qualified_prefix, identity_table, discovered, renames,
                                self_prefix, singleton_cref: singleton_cref)
          end
          unnameable = DeclarationWalk::Rules.unnameable_eval_self?(false, self_prefix, qualified_prefix,
                                                                    singleton_cref)
          eval_self = DeclarationWalk::Rules.eval_receiver_prefix(node, self_prefix || qualified_prefix,
                                                                  qualified_prefix, unnameable_self: unnameable) || []
          if (body = node.block.body)
            record_declarations(body, qualified_prefix, identity_table, discovered, renames,
                                eval_self, singleton_cref: singleton_cref)
          end
          true
        end

        private_class_method :file_compact_header_renames, :record_declarations, :record_class_or_module?,
                             :record_meta_new_constant?, :record_eval_declarations?
      end
    end
  end
end
