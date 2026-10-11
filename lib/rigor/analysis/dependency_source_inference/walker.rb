# frozen_string_literal: true

require "prism"

require_relative "mixin_scan"
require_relative "return_type_heuristic"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../../source/node_walker"
require_relative "../../inference/scope_indexer"
require_relative "../../inference/refine_census"

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
        # only after `using`.
        #
        # Issue #1814 — what the walk read, for the question "has every file that could refine module M been read?".
        # `modules` is every class and module the gem's files declare, as the project walk names them
        # (`ScopeIndexer.collect_class_decls`), every module its refinement rows name, and every module its mixin calls
        # name by a constant ({MixinScan#targets}), so a gem that mixes into another gem's module spoils it. `unread`
        # holds the gem-relative path of each file the walk could not read in full (it did not parse, could not be
        # read, or the census raised on it), or the gem directory when the walk itself raised; none is reported to the
        # user, whose diagnostic stream is the project's. `mixes_modules` is true when the source may change which
        # modules a module includes or prepends ({MixinScan}), which `using` activates along with the module.
        class Outcome < Data.define(:catalog, :truncated, :refinements, :modules, :unread, :mixes_modules)
          def initialize(catalog:, truncated:, refinements: {}.freeze, modules: Set.new.freeze, unread: [].freeze,
                         mixes_modules: false)
            super
          end

          def truncated? = truncated

          # Issue #1814 — a module this gem declares is fully read when the budget did not stop the walk, every `.rb`
          # file under the accepted roots was read, and no mixin site can have given the module an ancestor the walk
          # did not see. (A module another gem also declares is judged on every gem that does:
          # {Index#fully_read_module?}.)
          def fully_read? = !truncated && unread.empty? && !mixes_modules
        end

        # The walk's accumulators. The budget counts `catalog` only, but stops the whole walk: a refine body reached
        # after it trips is not recorded. `root` is the file being walked and `in_effect` its
        # {Inference::InEffectRefinements}, built the first time a `refine`-shaped call asks (issue #1689). Issue
        # #1814 — `modules`, `unread` and `mixes` are {Outcome}'s coverage facts, `targets` the modules its mixin calls
        # name ({MixinScan#targets}), `gem_dir` makes `unread` paths gem-relative, and `files` holds the parsed files,
        # which the constant-alias rewrite reads again.
        Harvest = Struct.new(:catalog, :refinements, :root, :in_effect, :gem_dir, :modules, :unread, :mixes, :files,
                             :targets) do
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

        # The constant-write nodes whose target is a bare name, and the ones whose target is a path.
        CONSTANT_WRITES = [
          Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
          Prism::ConstantOperatorWriteNode, Prism::ConstantTargetNode
        ].freeze
        CONSTANT_PATH_WRITES = [
          Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode,
          Prism::ConstantPathOperatorWriteNode
        ].freeze
        private_constant :CONSTANT_WRITES, :CONSTANT_PATH_WRITES

        module_function

        # @param gem_dir — absolute path to the gem's installation directory.
        # @param roots — subdirectory names within the gem to walk (defaults to `["lib"]` per
        #   `Configuration::Dependencies::Entry`).
        # @param budget — per-gem catalog cap (method-definition count). When unset, defaults
        #   to `UNBOUNDED` for backwards-compatible test paths.
        # @return frozen wrapper carrying the catalog (`Hash{[class_name, method_name] =>
        #   :instance | :singleton}`) and a `truncated?` flag set when the walker stopped harvesting because
        #   the budget was reached. Methods of identical name on the same class with different kinds (rare;
        #   private API mostly) carry the kind that wins the per-class first walk.
        def walk(gem_dir:, roots:, budget: UNBOUNDED)
          harvest = Harvest.new({}, {}, nil, nil, gem_dir.to_s, Set.new, [], false, [], Set.new)
          truncated = false
          accepted_roots(roots).each do |root|
            break if truncated

            truncated = walk_root(File.join(gem_dir.to_s, root), harvest, budget)
          end
          refinements = Inference::ScopeIndexer.freeze_refinements(rewrite_aliased_targets(harvest))
          Outcome.new(catalog: harvest.catalog.freeze, truncated: truncated,
                      refinements: refinements,
                      modules: (harvest.modules | harvest.targets | refining_modules(refinements)).freeze,
                      unread: harvest.unread.freeze, mixes_modules: harvest.mixes)
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

          files = Dir.glob(File.join(root_dir, "**", "*.rb"))
          unwalked_paths(root_dir, files).each { |path| harvest.unread << relative_path(path, harvest) }
          files.each do |path|
            harvest_file(path, harvest, budget)
            return true if harvest.catalog.size >= budget
          end
          false
        end

        # Issue #1814 — what `require` reaches under `root_dir` and the `**` glob does not enter: a dot file or
        # directory (`lib/.vendor/x.rb`) and a symlinked directory (`lib/compat -> ../shim`; Ruby 4.0.5 lists the link,
        # never what it holds). Their files may declare or refine a module, so the gem is not read in full.
        def unwalked_paths(root_dir, walked)
          dotted = Dir.glob(File.join(root_dir, "**", "*.rb"), File::FNM_DOTMATCH) - walked
          directories = Dir.glob(File.join(root_dir, "**", "*/"), File::FNM_DOTMATCH)
          dotted + directories.map { |dir| dir.chomp(File::SEPARATOR) }.select { |dir| File.symlink?(dir) }
        end

        # Issue #1814 — a file that does not parse, cannot be read, or raises under the census is recorded in
        # `harvest.unread`: it may have declared or refined anything, so the gem is not fully read. The user-facing
        # diagnostic stream is reserved for the project source; opt-in gem source MUST NOT pollute it with parse errors
        # the user cannot fix, so the signal is {Outcome#unread}, which only {Index#fully_read_module?} reads.
        def harvest_file(path, harvest, budget)
          parse_result = Prism.parse_file(path)
          return harvest.unread << relative_path(path, harvest) unless parse_result.errors.empty?

          harvest.root = parse_result.value
          harvest.in_effect = nil
          harvest.files << path
          record_coverage(parse_result.value, harvest)
          record_refinements(parse_result.value, harvest)
          walk_node(parse_result.value, [], false, harvest, budget)
        rescue StandardError
          harvest.unread << relative_path(path, harvest)
        end

        def relative_path(path, harvest) = path.delete_prefix(harvest.gem_dir).delete_prefix(File::SEPARATOR)

        # Issue #1814 — the classes and modules the file declares, as the project's `discovered_classes` names them, and
        # whether it holds a mixin site.
        def record_coverage(root, harvest)
          declared = {}
          Inference::ScopeIndexer.collect_class_decls(root, [], declared)
          harvest.modules.merge(declared.keys)
          scan = MixinScan.scan(root)
          harvest.mixes ||= scan.site
          harvest.targets.merge(scan.targets)
        end

        # ADR-121 WD7 (issue #1814) — the refinement table the file contributes, read by the census the project walk
        # runs ({Inference::ScopeIndexer.refinement_table}): the `refine` bodies, the computed targets, the `refine`
        # inside a method, the `:refine` literals, and the wildcard rows each leaves.
        def record_refinements(root, harvest)
          harvest.refinements = Inference::ScopeIndexer.merge_refinement_tables(
            harvest.refinements, Inference::ScopeIndexer.refinement_table(root)
          )
        end

        # Issue #1814 — a refine target a gem's own constant write binds (`K = String; refine(K) { … }`) names whatever
        # value the write holds, which the walker cannot resolve: the project reading learns it at read time, from the
        # project's constant census (`Scope#bound_constant_names`), which holds no gem's writes. So a row keyed by a
        # name whose last segment a gem file writes (`K = …`, `A::K = …`, `K ||= …`, `K, L = …`, `const_set(:K, …)`),
        # and that no gem file declares as a class or module, is moved to the wildcard class: the class-unknown row the
        # project reading gives the same constant. The body's names decline on every receiver, and a call a row
        # replaces types `Dynamic[top]`. The writes of every file are needed, so the files are read again; a gem with
        # no refinement row reads none.
        def rewrite_aliased_targets(harvest)
          table = harvest.refinements
          return table if table.empty?

          bound = bound_constant_segments(harvest.files)
          wildcard = Scope::DiscoveryIndex::REFINEMENT_WILDCARD
          table.inject({}) do |out, (class_name, methods)|
            aliased = class_name != wildcard && !harvest.modules.include?(class_name) &&
                      bound.include?(class_name.split("::").last)
            Inference::ScopeIndexer.merge_refinement_tables(out, { (aliased ? wildcard : class_name) => methods })
          end
        end

        # The last segments of the constants the `files` write by any form (an assignment, a path write, an operator
        # write, a multiple assignment, a `const_set` with a literal name).
        def bound_constant_segments(files)
          segments = Set.new
          files.each do |path|
            Source::NodeWalker.each(Prism.parse_file(path).value) { |node| segments << bound_segment(node) }
          rescue StandardError
            next # the file is already in `unread`
          end
          segments.delete(nil)
          segments
        end

        def bound_segment(node)
          case node
          when *CONSTANT_WRITES, Prism::ConstantPathTargetNode then node.name.to_s
          when *CONSTANT_PATH_WRITES then node.target.name.to_s
          when Prism::CallNode then const_set_name(node)
          end
        end

        def const_set_name(call)
          name = call.name == :const_set && call.arguments&.arguments&.first
          name.unescaped if name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)
        end

        # The modules the rows of `table` name as refining, without the wildcard (a module the walk cannot name) and the
        # top level's `""` (where Ruby raises).
        def refining_modules(table)
          wildcard = Scope::DiscoveryIndex::REFINEMENT_WILDCARD
          table.each_value.flat_map { |methods| methods.each_value.flat_map(&:itself) }.to_set - [wildcard, ""]
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
