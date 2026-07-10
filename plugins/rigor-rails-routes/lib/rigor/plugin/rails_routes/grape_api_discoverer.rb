# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class RailsRoutes < Rigor::Plugin::Base
      # Recognises the helper *namespaces* the `grape-path-helpers` gem generates, so a call to one of them
      # does not false-fire `unknown-helper`.
      #
      # The gem names each helper after its route's path segments, joined with `_`
      # (`DecoratedRoute#path_helper_name`): `/api/:version/groups/:id/badges` under `version 'v4'` becomes
      # `api_v4_groups_badges_path`. It walks `Grape::API::Instance.routes` — the *runtime* route table — and
      # real grape sources build that table with metaprogramming (GitLab's `%w[group project].each { |t|
      # resource t.pluralize … }`). A static parser cannot enumerate those names, and deriving only the
      # easy ones would be worse than deriving none: every route it missed would keep firing on working
      # code.
      #
      # What IS static is the leading segments. `prefix :api` contributes the first; `version 'v4'`
      # contributes the second when the strategy is `:path` (Grape's default — `using: :header` / `:param`
      # keeps the version out of the URL, and so out of the helper name). Both are literal arguments in the
      # body of a class whose superclass chain reaches `Grape::API`. Everything after them is opaque.
      #
      # So the namespace `api_v4_…_path` is treated as open — a name the project's routes may define but
      # Rigor cannot enumerate, so proving it undefined is unsound (the ADR-26 `open_receivers` reasoning,
      # already applied in this plugin to Devise's runtime-provider OmniAuth family). Teeth survive where the
      # gem's own contract keeps them sound: it defines no `_url` helper
      # (`NamedRouteMatcher#method_missing` returns `super` unless the name ends `_path`), so
      # `api_v4_anything_url` still fires, as does any name outside a declared prefix.
      #
      # Design note: `docs/notes/20260710-grape-path-helper-namespace.md`.
      module GrapeApiDiscoverer
        # A class is a grape API when its superclass chain reaches one of these. `Grape::API::Instance` is
        # what a mounted `Grape::API` subclass actually becomes, and real code inherits from it directly
        # (GitLab's `API::Base < Grape::API::Instance`).
        GRAPE_BASE_NAMES = ["Grape::API", "Grape::API::Instance"].freeze

        # `version 'v4', using: :path` puts the version in the URL. `:header` / `:param` do not, so those
        # versions contribute no helper-name segment. Grape's default strategy is `:path`.
        PATH_VERSION_STRATEGY = :path

        module_function

        # @param contents_per_path [Hash{String => String}] file path → source text, read by the caller
        #   (through the trusted `IoBoundary`, so cache invalidation works).
        # @return [Array<String>] the recognised helper-name prefixes (`["api_v3", "api_v4"]`). Empty when
        #   the project declares no grape API — nothing changes for such a project.
        def discover(contents_per_path)
          declarations = {}
          superclasses = {}
          contents_per_path.each_value do |contents|
            collect_from_contents(contents, declarations, superclasses)
          rescue StandardError
            # Best-effort: a parse failure in one grape file must not abort discovery for the rest. The core
            # pipeline surfaces the parse error separately.
            next
          end
          prefixes_for(declarations, superclasses)
        end

        # Composes `prefix` × `version` into helper-name prefixes, for grape classes only. A class with a
        # prefix and no path-strategy version contributes the bare prefix; one with versions and no prefix
        # contributes each version alone.
        def prefixes_for(declarations, superclasses)
          declarations.filter_map do |class_name, declaration|
            next unless grape_api?(class_name, superclasses)

            segments = declaration[:prefix]
            versions = declaration[:versions]
            next segments.join("_") if versions.empty? && !segments.empty?

            versions.map { |version| (segments + [version]).join("_") }
          end.flatten.reject(&:empty?).uniq
        end

        # Follows the recorded superclass chain (cycle-guarded) looking for a grape base. The chain lives
        # entirely inside the scanned files, so an unresolvable parent simply ends the walk.
        def grape_api?(class_name, superclasses)
          seen = {}
          current = class_name
          while current && !seen[current]
            seen[current] = true
            parent = superclasses[current]
            return true if parent && GRAPE_BASE_NAMES.include?(parent)

            current = parent
          end
          false
        end

        def collect_from_contents(contents, declarations, superclasses)
          root = Prism.parse(contents).value
          walk(root, [], declarations, superclasses)
        end

        def walk(node, prefix_path, declarations, superclasses)
          return unless node.is_a?(Prism::Node)

          if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
            name = constant_name(node.constant_path)
            if name
              qualified = (prefix_path + [name]).join("::")
              record_class(node, qualified, declarations, superclasses) if node.is_a?(Prism::ClassNode)
              walk(node.body, prefix_path + [name], declarations, superclasses) if node.body
              return
            end
          end

          node.compact_child_nodes.each { |child| walk(child, prefix_path, declarations, superclasses) }
        end

        def record_class(node, qualified, declarations, superclasses)
          parent = constant_name(node.superclass)
          superclasses[qualified] = parent if parent
          declaration = { prefix: [], versions: [] }
          statements_of(node.body).each { |statement| absorb_declaration(statement, declaration) }
          declarations[qualified] = declaration unless declaration[:prefix].empty? && declaration[:versions].empty?
        end

        # `prefix :api` / `prefix 'api/v2'` (a multi-segment prefix splits on `/`), and `version 'v4'` /
        # `version 'v4', using: :path` — both in block and non-block form.
        def absorb_declaration(node, declaration)
          return unless node.is_a?(Prism::CallNode) && node.receiver.nil?

          case node.name
          when :prefix
            value = literal_value(first_argument(node))
            declaration[:prefix] = value.split("/").reject(&:empty?) if value
          when :version
            value = literal_value(first_argument(node))
            declaration[:versions] << value if value && path_strategy?(node)
          end
        end

        # True unless an explicit `using:` names a non-path strategy. Grape defaults to `:path`.
        def path_strategy?(node)
          arguments = node.arguments&.arguments || []
          keywords = arguments.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
          return true if keywords.nil?

          using = keywords.elements.find do |element|
            element.is_a?(Prism::AssocNode) && literal_value(element.key) == "using"
          end
          return true if using.nil?

          literal_value(using.value) == PATH_VERSION_STRATEGY.to_s
        end

        def first_argument(node)
          node.arguments&.arguments&.first
        end

        # Symbol and String literals only. A computed prefix / version is not a declaration we can ground a
        # namespace in, so it contributes nothing.
        def literal_value(node)
          case node
          when Prism::SymbolNode, Prism::StringNode then node.unescaped
          end
        end

        def constant_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_name(node)
          end
        end

        def constant_path_name(node)
          parent = node.parent
          own = node.name&.to_s
          return nil unless own
          return own if parent.nil? # `::Foo` — a cbase root

          parent_name = constant_name(parent)
          parent_name ? "#{parent_name}::#{own}" : own
        end

        def statements_of(body)
          case body
          when Prism::StatementsNode then body.body
          when Prism::BeginNode then statements_of(body.statements)
          when nil then []
          else [body]
          end
        end
      end
    end
  end
end
