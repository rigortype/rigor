# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module DependencySourceInference
      # Walks a resolved gem's `roots:` and collects the
      # `(class_name, method_name) → :instance | :singleton`
      # method catalog. The walker is the source of facts the
      # dispatcher tier (slice 2b-ii) consults to recognise a
      # method as defined by an opt-in gem and contribute a
      # `Type::Dynamic` return at the call site.
      #
      # Slice 2b-i intentionally collects only the catalog, not
      # the inferred return type. The dispatcher tier returns
      # `Dynamic[top]` on a hit until slice 2b-ii wires return-
      # type inference; the visible payoff today is removing the
      # `call.undefined-method` diagnostic for opt-in gem methods
      # at receivers Rigor knows by `Nominal[T]` (typically
      # because the user authored an RBS skeleton).
      #
      # Hard exclusions are NOT user-configurable, per ADR-10
      # § "Hard exclusions": top-level `spec/`, `test/`, `bin/`,
      # plus any non-`.rb` source. C extensions fall out
      # automatically because the walker only loads `.rb` files.
      module Walker
        # Top-level directories that MUST NOT participate in
        # gem-source inference even when the user lists them
        # under `roots:`. The check is case-insensitive against
        # the first segment of `roots:`; nested `spec/` /
        # `test/` directories deeper inside `lib/` are NOT
        # filtered (a few gems legitimately ship `lib/.../spec/`).
        HARD_EXCLUDED_ROOTS = %w[spec test bin].freeze

        module_function

        # @param gem_dir [String, Pathname] absolute path to the
        #   gem's installation directory.
        # @param roots [Array<String>] subdirectory names within
        #   the gem to walk (defaults to `["lib"]` per
        #   `Configuration::Dependencies::Entry`).
        # @return [Hash{[String, Symbol] => Symbol}] flat catalog
        #   mapping `[class_name, method_name]` to the method
        #   kind (`:instance` or `:singleton`). Methods of
        #   identical name on the same class with different
        #   kinds (rare; private API mostly) carry the kind that
        #   wins the per-class first walk.
        def walk(gem_dir:, roots:)
          accumulator = {}
          accepted_roots(roots).each do |root|
            walk_root(File.join(gem_dir.to_s, root), accumulator)
          end
          accumulator.freeze
        end

        # Drops hard-excluded entries before any filesystem
        # walk happens. Reasoning: we never want a gem's
        # `spec/` to participate even if the user requested
        # it — the noise from RSpec-style globals plus the
        # cost of walking test fixtures isn't worth the
        # marginal coverage.
        def accepted_roots(roots)
          roots.reject { |root| HARD_EXCLUDED_ROOTS.include?(root.downcase) }
        end

        def walk_root(root_dir, accumulator)
          return unless File.directory?(root_dir)

          Dir.glob(File.join(root_dir, "**", "*.rb")).each do |path|
            harvest_file(path, accumulator)
          end
        end

        def harvest_file(path, accumulator)
          parse_result = Prism.parse_file(path)
          return unless parse_result.errors.empty?

          walk_node(parse_result.value, [], false, accumulator)
        rescue StandardError
          # Gem source we can't parse / read silently degrades
          # to "no contribution from this file". The user-facing
          # diagnostic stream is reserved for the project source;
          # opt-in gem source MUST NOT pollute it with parse
          # errors the user cannot fix.
          nil
        end

        # Walks a Prism subtree, accumulating method definitions
        # under their qualified class name. Mirrors the shape of
        # `Inference::ScopeIndexer#walk_methods` but stays
        # decoupled from `Scope` because gem-source inference
        # runs without a scope context.
        def walk_node(node, qualified_prefix, in_singleton_class, accumulator)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            descend_class_or_module(node, qualified_prefix, in_singleton_class, accumulator)
          when Prism::SingletonClassNode
            descend_singleton_class(node, qualified_prefix, accumulator)
          when Prism::DefNode
            record_def_node(node, qualified_prefix, in_singleton_class, accumulator)
          else
            walk_children(node, qualified_prefix, in_singleton_class, accumulator)
          end
        end

        def walk_children(node, qualified_prefix, in_singleton_class, accumulator)
          node.compact_child_nodes.each do |child|
            walk_node(child, qualified_prefix, in_singleton_class, accumulator)
          end
        end

        # `class Foo` / `module Bar`. The dynamic-prefix shape
        # (`module ::Foo`-rooted variants whose left side is a
        # runtime expression) is treated as opaque — we walk the
        # children under the same prefix so any inner class
        # definitions are still recorded under their own name.
        def descend_class_or_module(node, qualified_prefix, in_singleton_class, accumulator)
          name = qualified_name_for(node.constant_path)
          if name && node.body
            walk_node(node.body, qualified_prefix + [name], in_singleton_class, accumulator)
          else
            walk_children(node, qualified_prefix, in_singleton_class, accumulator)
          end
        end

        # `class << self` only — `class << expr` for any other
        # `expr` is treated as opaque so we don't accidentally
        # record per-instance singleton methods under the
        # surrounding class.
        def descend_singleton_class(node, qualified_prefix, accumulator)
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_node(node.body, qualified_prefix, true, accumulator)
          else
            walk_children(node, qualified_prefix, false, accumulator)
          end
        end

        def record_def_node(node, qualified_prefix, in_singleton_class, accumulator)
          return if qualified_prefix.empty?

          class_name = qualified_prefix.join("::")
          kind = node.receiver.is_a?(Prism::SelfNode) || in_singleton_class ? :singleton : :instance
          accumulator[[class_name, node.name]] ||= kind
        end

        # Resolves a `Prism::ConstantPathNode` /
        # `Prism::ConstantReadNode` chain to its dot-separated
        # name (e.g. `"Foo::Bar"`). Returns nil for the rare
        # dynamic-prefix shape (`module ::Foo`-rooted variants
        # whose left side is a runtime expression) so the
        # walker treats those as opaque rather than guessing.
        def qualified_name_for(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parent = node.parent.nil? ? nil : qualified_name_for(node.parent)
            return nil if !node.parent.nil? && parent.nil?

            parent.nil? ? node.name.to_s : "#{parent}::#{node.name}"
          end
        end
      end
    end
  end
end
