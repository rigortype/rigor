# frozen_string_literal: true

require "prism"

require_relative "return_type_heuristic"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../../inference/scope_indexer"
require_relative "../../rooted_glob"

module Rigor
  module Analysis
    module DependencySourceInference
      # Walks a resolved gem's `roots:` and collects the `(class_name, method_name) → CatalogEntry(kind,
      # return_type)` method catalog. The walker is the source of facts the dispatcher tier consults to
      # recognise a method as defined by an opt-in gem and contribute a `Type::Dynamic`-wrapped return at
      # the call site.
      #
      # The dispatcher tier wraps every walker-contributed return in `Dynamic[T]` per ADR-10's gem-boundary
      # contract. When the heuristic ({ReturnTypeHeuristic}) recognises the method body's tail expression,
      # the dispatcher uses the heuristic's static facet; otherwise it falls back to `Dynamic[top]` (the
      # pre-heuristic behaviour). The heuristic is intentionally narrow — only literal-tail method bodies
      # fold; everything else degrades silently.
      #
      # Hard exclusions are NOT user-configurable, per ADR-10 § "Hard exclusions": top-level `spec/`,
      # `test/`, `bin/`, plus any non-`.rb` source. C extensions fall out automatically because the walker
      # only loads `.rb` files.
      module Walker
        # Top-level directories that MUST NOT participate in gem-source inference even when the user lists
        # them under `roots:`. The check is case-insensitive against the first segment of `roots:`; nested
        # `spec/` / `test/` directories deeper inside `lib/` are NOT filtered (a few gems legitimately ship
        # `lib/.../spec/`).
        HARD_EXCLUDED_ROOTS = %w[spec test bin].freeze

        # Walker outcome wrapping the harvested method catalog plus a budget-exceeded flag. ADR-10 slice 4
        # introduces the cap; the Walker stops appending to the accumulator once `catalog.size` reaches
        # `budget`, and `truncated?` reports whether the cap was reached. The Index records this per-gem so
        # the Runner can surface a single `dynamic.dependency-source.budget-exceeded` warning naming the
        # affected gem(s).
        #
        # Issue #1672 — `refinements` is the gem's `refine X do … end` table, `{refined class => {method =>
        # [refining modules]}}`, the shape `Inference::ScopeIndexer` builds for project files. A refine-body `def`
        # goes there and never into `catalog`: it is not a method of the refining module, and of the refined class
        # only after `using`. ADR-121 WD7 (issue #1814) — the table is the one the project walk's census records for
        # the same source ({Inference::ScopeIndexer.refinement_table}), file by file, so it carries the wildcard rows
        # a project module's would.
        #
        # Issue #1814 — `bound` is every name the gem's files bind by a constant write (an assignment, an operator
        # write, a multiple assignment, a rooted path write) without declaring a class or module by it, spelled under
        # the lexical nesting the write sits in (`Shared::Target` for `module Shared; Target = String; end`);
        # `bound_segments` is the last segment of each write whose owner the walk cannot spell (a path write that is
        # not rooted, a write under `class << …`, a `const_set` with a literal name) ({.collect_bound_constants}). A
        # refine key one of these binds (`refine(Shared::Target)` anywhere) may name any value, which the walker cannot
        # resolve: the rows stay as the census records them, {Index#bound_constant?} unions the names across the walked
        # gems, and the reader decides the key at read time, by each prefix of it
        # ({Inference::InEffectRefinements.class_wildcard_key?}).
        class Outcome < Data.define(:catalog, :truncated, :refinements, :bound, :bound_segments)
          def initialize(catalog:, truncated:, refinements: {}.freeze, bound: Set.new.freeze,
                         bound_segments: Set.new.freeze)
            super
          end

          def truncated? = truncated
        end

        # The walk's accumulators. The budget counts `catalog` only, but stops the whole walk: a file reached after it
        # trips is not read. `root` is the file being walked and `in_effect` its {Inference::InEffectRefinements}, built
        # the first time a `refine`-shaped call asks (issue #1689). Issue #1814 — `bound` and `bound_segments` are
        # {Outcome}'s.
        Harvest = Struct.new(:catalog, :refinements, :root, :in_effect, :bound, :bound_segments) do
          # {Inference::ScopeIndexer.module_refine_target} against this file's in-effect refinements.
          def refine_target_of(node)
            return nil if Inference::ScopeIndexer.refine_target(node).nil?

            self.in_effect ||= Inference::InEffectRefinements.new(root)
            Inference::ScopeIndexer.module_refine_target(node, in_effect)
          end
        end
        private_constant :Harvest

        # Per-method catalog entry. `kind` is `:instance` or `:singleton`; `return_type` is the
        # {ReturnTypeHeuristic}-extracted static facet (a `Rigor::Type::*`) or `nil` when the heuristic
        # declined. The dispatcher wraps a non-nil `return_type` in `Dynamic[T]`; a `nil` `return_type` falls
        # back to `Dynamic[top]`.
        class CatalogEntry < Data.define(:kind, :return_type)
          def initialize(kind:, return_type: nil)
            super
          end
        end

        # Sentinel for "no cap" — used by callers that don't care about the budget (specs, tooling).
        # Production code MUST pass an integer.
        UNBOUNDED = Float::INFINITY

        module_function

        # @param gem_dir — absolute path to the gem's installation directory.
        # @param roots — subdirectory names within the gem to walk (defaults to `["lib"]` per
        #   `Configuration::Dependencies::Entry`).
        # @param budget — per-gem catalog cap (method-definition count). When unset, defaults
        #   to `UNBOUNDED` for backwards-compatible test paths.
        # @return frozen wrapper carrying the catalog (keyed by `[class_name, method_name]`, valued by
        #   {CatalogEntry}) and a `truncated?` flag set when the walker stopped harvesting because the budget was
        #   reached. Methods of identical name on the same class with different kinds (rare; private API mostly)
        #   carry the kind that wins the per-class first walk.
        def walk(gem_dir:, roots:, budget: UNBOUNDED)
          harvest = Harvest.new({}, {}, nil, nil, Set.new, Set.new)
          truncated = false
          accepted_roots(roots).each do |root|
            break if truncated

            truncated = walk_root(File.join(gem_dir.to_s, root), harvest, budget)
          end
          Outcome.new(catalog: harvest.catalog.freeze, truncated: truncated,
                      refinements: Inference::ScopeIndexer.freeze_refinements(harvest.refinements),
                      bound: harvest.bound.freeze, bound_segments: harvest.bound_segments.freeze)
        end

        # Drops hard-excluded entries before any filesystem walk happens. Reasoning: we never want a gem's
        # `spec/` to participate even if the user requested it — the noise from RSpec-style globals plus
        # the cost of walking test fixtures isn't worth the marginal coverage.
        def accepted_roots(roots)
          roots.reject { |root| HARD_EXCLUDED_ROOTS.include?(root.downcase) }
        end

        # Returns true when the budget tripped during this root's walk so the caller can stop iterating
        # subsequent roots.
        def walk_root(root_dir, harvest, budget) # rubocop:disable Naming/PredicateMethod
          return false unless File.directory?(root_dir)

          RootedGlob.glob(root_dir, "**/*.rb").each do |path|
            harvest_file(path, harvest, budget)
            return true if harvest.catalog.size >= budget
          end
          false
        end

        def harvest_file(path, harvest, budget)
          parse_result = Prism.parse_file(path)
          return unless parse_result.errors.empty?

          harvest.root = parse_result.value
          harvest.in_effect = nil
          record_refinements(parse_result.value, path, harvest)
          collect_bound_constants(parse_result.value, [[]], harvest)
          walk_node(parse_result.value, [], false, harvest, budget)
        rescue StandardError
          # Gem source we can't parse / read silently degrades to "no contribution from this file". The
          # user-facing diagnostic stream is reserved for the project source; opt-in gem source MUST NOT
          # pollute it with parse errors the user cannot fix.
          nil
        end

        # ADR-121 WD7 (issue #1814) — the refinement table the file contributes, read by the census the project walk
        # runs ({Inference::ScopeIndexer.refinement_table}): the `refine` bodies, the computed targets, the `refine`
        # inside a method, the `:refine` literals, and the wildcard rows each leaves, folded as the project folds its
        # files' tables (`merge_refinement_tables`). The walker's own descent below records no row.
        def record_refinements(root, path, harvest)
          harvest.refinements = Inference::ScopeIndexer.merge_refinement_tables(
            harvest.refinements, Inference::ScopeIndexer.refinement_table(root, path)
          )
        end

        # Issue #1814 — the names the file binds by a constant write without declaring a class or module by them, or
        # the last segment alone where the walk cannot spell the owner Ruby binds. A bare write (`K = …`, `K ||= …`,
        # `K += …`, a multiple-assignment target) binds the name under the lexical nesting of the `class` / `module`
        # headers around it, which a block does not change (a `Module.new do … end` or `module_eval { … }` body assigns
        # a constant in the lexical scope around it); `prefixes` holds every nesting the headers can denote, since a
        # nested compact header opens whichever module Ruby finds (`module W; module Shared::Inner` is
        # `W::Shared::Inner` or `Shared::Inner`), as the census spells a refine target. A write whose value is one of
        # the class-creating shapes the project walk registers as a declaration (`Class.new`, `Module.new`,
        # `Struct.new`, `Data.define`, a `.freeze` tail or a `K = K || …` guard stripped:
        # {Inference::ScopeIndexer.meta_new_rvalue}) declares a class, so `Point = Struct.new(:x); refine(Point)` keeps
        # a normal row. Where the owner cannot be spelled the segment alone is recorded, which matches that segment of
        # any key: a write under `class << …` (the singleton's), a path write that is not rooted (`Wrap::K = …` may
        # bind under an included module's `Wrap`; `self::K = …` in a block binds under the block's `self`), and a
        # `const_set` with a literal name (`Object.const_set(:K, …)` binds `::K`). A rooted path (`::Shared::K = …`)
        # binds that name. One pass over the tree; the rows are not touched.
        def collect_bound_constants(node, prefixes, harvest)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode then prefixes = header_prefixes(node.constant_path, prefixes)
          when Prism::SingletonClassNode then prefixes = nil
          when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
               Prism::ConstantOperatorWriteNode
            note_bare_write(node.name.to_s, prefixes, harvest) unless declares_class?(node)
          when Prism::ConstantTargetNode then note_bare_write(node.name.to_s, prefixes, harvest)
          when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode,
               Prism::ConstantPathOperatorWriteNode
            note_path_write(node.target, harvest) unless declares_class?(node)
          when Prism::ConstantPathTargetNode then note_path_write(node, harvest)
          when Prism::CallNode then note_const_set(node, harvest)
          end
          node.rigor_each_child { |child| collect_bound_constants(child, prefixes, harvest) }
        end

        def declares_class?(write)
          rvalue = Inference::ScopeIndexer.meta_new_rvalue(write)
          !rvalue.nil? && Inference::ScopeIndexer.meta_new_constant_rvalue?(rvalue)
        end

        # The nestings a `class` / `module` body may sit in, given the ones its header is written in: a bare header
        # opens a module under each; a compact header (`module Shared::Inner`) opens `Inner` under every name its base
        # can denote there ({Inference::ScopeIndexer.constant_receiver_candidates}); a rooted header resets them. nil,
        # the unspellable owner, for a header no constant spells or one under `class << …`.
        def header_prefixes(constant_path, prefixes)
          return nil if prefixes.nil? || Source::ConstantPath.qualified_name_or_nil(constant_path).nil?
          return [Source::ConstantPath.qualified_name_or_nil(constant_path).split("::")] if rooted_path?(constant_path)

          name = constant_path.name.to_s
          return prefixes.map { |prefix| prefix + [name] } if constant_path.is_a?(Prism::ConstantReadNode)

          prefixes.flat_map do |prefix|
            Inference::ScopeIndexer.constant_receiver_candidates(constant_path.parent, prefix)
                                   .map { |owner| owner.split("::") + [name] }
          end.uniq
        end

        # `::K`, `::A::K`, as a path or a multiple-assignment target: the leftmost segment has no parent.
        def rooted_path?(path)
          path.respond_to?(:parent) && (path.parent.nil? || Source::ConstantPath.rooted?(path.parent))
        end

        def note_bare_write(name, prefixes, harvest)
          return harvest.bound_segments << name if prefixes.nil?

          prefixes.each { |prefix| harvest.bound << (prefix + [name]).join("::") }
        end

        # A path write binds its name where its base resolves, which the walk can spell only for a rooted base.
        def note_path_write(path, harvest)
          name = path.name.to_s
          return harvest.bound_segments << name unless rooted_path?(path)

          owner = path.parent && Source::ConstantPath.qualified_name_or_nil(path.parent)
          harvest.bound << (owner ? "#{owner}::#{name}" : name)
        end

        # `const_set(:K, value)` / `const_set("K", value)` with a literal name, on any receiver: the owner is a value.
        # A class-creating value declares a class, as a write of one does.
        def note_const_set(node, harvest)
          return unless node.name == :const_set

          name, value = node.arguments&.arguments
          return unless name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)
          return if value && Inference::ScopeIndexer.meta_new_constant_rvalue?(value)

          harvest.bound_segments << name.unescaped
        end

        # Walks a Prism subtree, accumulating method definitions under their qualified class name. Mirrors
        # the shape of `Inference::ScopeIndexer#walk_methods` but stays decoupled from `Scope` because
        # gem-source inference runs without a scope context.
        def walk_node(node, qualified_prefix, in_singleton_class, harvest, budget)
          return unless node.is_a?(Prism::Node)
          return if harvest.catalog.size >= budget

          case node
          when Prism::ClassNode, Prism::ModuleNode
            descend_class_or_module(node, qualified_prefix, in_singleton_class, harvest, budget)
          when Prism::SingletonClassNode
            descend_singleton_class(node, qualified_prefix, harvest, budget)
          when Prism::DefNode
            record_def_node(node, qualified_prefix, in_singleton_class, harvest, budget)
          when Prism::CallNode
            return walk_refine_body(node, qualified_prefix, harvest, budget) if harvest.refine_target_of(node)

            walk_children(node, qualified_prefix, in_singleton_class, harvest, budget)
          else
            walk_children(node, qualified_prefix, in_singleton_class, harvest, budget)
          end
        end

        def walk_children(node, qualified_prefix, in_singleton_class, harvest, budget)
          node.rigor_each_child do |child|
            break if harvest.catalog.size >= budget

            walk_node(child, qualified_prefix, in_singleton_class, harvest, budget)
          end
        end

        # `class Foo` / `module Bar`. The dynamic-prefix shape (`module ::Foo`-rooted variants whose left
        # side is a runtime expression) is treated as opaque — we walk the children under the same prefix
        # so any inner class definitions are still recorded under their own name.
        def descend_class_or_module(node, qualified_prefix, in_singleton_class, harvest, budget)
          name = Source::ConstantPath.qualified_name_or_nil(node.constant_path)
          if name && node.body
            child_prefix = Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
            walk_node(node.body, child_prefix, in_singleton_class, harvest, budget)
          else
            walk_children(node, qualified_prefix, in_singleton_class, harvest, budget)
          end
        end

        # `class << self` only — `class << expr` for any other `expr` is treated as opaque so we don't
        # accidentally record per-instance singleton methods under the surrounding class.
        def descend_singleton_class(node, qualified_prefix, harvest, budget)
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_node(node.body, qualified_prefix, true, harvest, budget)
          else
            walk_children(node, qualified_prefix, false, harvest, budget)
          end
        end

        def record_def_node(node, qualified_prefix, in_singleton_class, harvest, _budget)
          return if qualified_prefix.empty?

          class_name = qualified_prefix.join("::")
          kind = node.receiver.is_a?(Prism::SelfNode) || in_singleton_class ? :singleton : :instance
          key = [class_name, node.name]
          return if harvest.catalog.key?(key) # first walk wins

          return_type = ReturnTypeHeuristic.extract(node)
          harvest.catalog[key] = CatalogEntry.new(kind: kind, return_type: return_type)
        end

        # Issue #1672 — `refine X do … end`, the shape {Inference::ScopeIndexer.module_refine_target} accepts (not one
        # whose `self` is a class: that is the class's own method and walks as any other call, issue #1689). The body's
        # instance `def`s are refinements of X by the enclosing module, and none reaches the catalogue. The refinement
        # table is not built here: {.record_refinements} runs the project walk's census over the whole file, which reads
        # this body and every other `refine`-shaped node (ADR-121 WD7, issue #1814). Declarations nested in the body
        # still walk under the lexical prefix, as they did before.
        def walk_refine_body(node, qualified_prefix, harvest, budget)
          body = node.block.body
          walk_refine_declarations(body, qualified_prefix, harvest, budget) unless body.nil?
        end

        # The class / module declarations inside a refine body, walked as before; nothing else in it is.
        def walk_refine_declarations(node, qualified_prefix, harvest, budget)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            walk_node(node, qualified_prefix, false, harvest, budget)
          when Prism::DefNode, Prism::SingletonClassNode
            nil
          else
            node.rigor_each_child { |child| walk_refine_declarations(child, qualified_prefix, harvest, budget) }
          end
        end
      end
    end
  end
end
