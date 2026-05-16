# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class DryTypes < Rigor::Plugin::Base
      # Walks project source for `module X; include Dry.Types(); end`
      # shapes and emits a `{ "<X>::<Alias>" => "<UnderlyingClass>" }`
      # alias table covering the dry-types canonical-shortcut names.
      # See {DryTypes} module-docstring for the floor / ceiling
      # scoping.
      module AliasScanner
        # The canonical-shortcut names dry-types exposes through
        # `include Dry.Types()`. Mirrors `Dry::Types.type_keys`
        # from the upstream gem; nested categories
        # (`Coercible::*` / `Strict::*` / `Params::*` / `JSON::*`)
        # are a separate slice and stay deferred.
        CANONICAL_ALIASES = {
          "String" => "String",
          "Integer" => "Integer",
          "Float" => "Float",
          "Decimal" => "BigDecimal",
          "Symbol" => "Symbol",
          "Bool" => "TrueClass",
          "True" => "TrueClass",
          "False" => "FalseClass",
          "Nil" => "NilClass",
          "Date" => "Date",
          "DateTime" => "DateTime",
          "Time" => "Time",
          "Hash" => "Hash",
          "Array" => "Array",
          "Any" => "Object"
        }.freeze

        module_function

        # @param paths [Array<String>] absolute paths to `.rb`
        #   files the project's `paths:` resolves to.
        # @return [Hash{String => String}] frozen
        #   `{aliased_name => underlying_class_name}` map. Empty
        #   when no `include Dry.Types()` declaration is found.
        def scan(paths:)
          modules = paths.flat_map { |path| scan_file(path) }.uniq
          return {}.freeze if modules.empty?

          modules.each_with_object({}) do |module_name, acc|
            CANONICAL_ALIASES.each do |alias_name, underlying|
              acc["#{module_name}::#{alias_name}"] = underlying
            end
          end.freeze
        end

        def scan_file(path)
          source = File.read(path)
          parse_result = Prism.parse(source, filepath: path)
          return [] unless parse_result.errors.empty?

          collect_alias_modules(parse_result.value, [])
        rescue StandardError
          # Missing-file / parse failures degrade to "no
          # contribution from this file"; the plugin's
          # user-visible surface is the published fact, and
          # dropping unparseable files keeps the fact stable.
          []
        end
        private_class_method :scan_file

        # Walks a Prism AST collecting module names that contain a
        # tail-statement `include Dry.Types()` call. Tracks the
        # enclosing module chain so a nested
        # `module App; module Types; include Dry.Types(); end; end`
        # publishes `"App::Types"` as the alias scope.
        def collect_alias_modules(node, qualified_prefix)
          return [] unless node.is_a?(Prism::Node)

          case node
          when Prism::ModuleNode
            name = qualified_name_for(node.constant_path)
            new_prefix = name ? qualified_prefix + [name] : qualified_prefix
            children = node.body ? collect_alias_modules(node.body, new_prefix) : []
            current_module = name && contains_dry_types_include?(node.body) ? [new_prefix.join("::")] : []
            current_module + children
          when Prism::ClassNode
            # Module-level declarations win; we don't recurse into
            # class bodies for `include Dry.Types()` because the
            # canonical pattern is module-level.
            []
          else
            node.compact_child_nodes.flat_map { |c| collect_alias_modules(c, qualified_prefix) }
          end
        end
        private_class_method :collect_alias_modules

        # `include Dry.Types()` at the top of the module body is the
        # canonical alias declaration. We accept the call anywhere
        # in the body (some projects guard it with a `if defined?`
        # check). The argument list must be empty (or a kwargs-only
        # `default: :nominal` style accepted by upstream; we treat
        # both as "alias-installing").
        def contains_dry_types_include?(body)
          return false if body.nil?

          tree_walk(body).any? do |child|
            include_call_targeting_dry_types?(child)
          end
        end
        private_class_method :contains_dry_types_include?

        def tree_walk(node)
          return [] unless node.is_a?(Prism::Node)

          Enumerator.new do |y|
            stack = [node]
            until stack.empty?
              current = stack.shift
              y << current
              stack.concat(current.compact_child_nodes) if current.is_a?(Prism::Node)
            end
          end
        end
        private_class_method :tree_walk

        # Matches `include Dry.Types()` (with or without kwargs).
        # The receiver of the include call MUST be implicit
        # (i.e., called on `self`), and the argument MUST be a
        # method call on the `Dry` constant naming `Types`.
        def include_call_targeting_dry_types?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless node.name == :include && node.receiver.nil?
          return false if node.arguments.nil?
          return false unless node.arguments.arguments.size == 1

          arg = node.arguments.arguments.first
          dry_types_call?(arg)
        end
        private_class_method :include_call_targeting_dry_types?

        def dry_types_call?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless node.name == :Types
          return false unless node.receiver.is_a?(Prism::ConstantReadNode)

          node.receiver.name == :Dry
        end
        private_class_method :dry_types_call?

        # Resolves a `Prism::ConstantPathNode` /
        # `Prism::ConstantReadNode` chain to its dot-separated
        # name (e.g. `"App::Types"`). Returns nil for the
        # dynamic-prefix shape so the scanner treats those as
        # opaque rather than guessing.
        def qualified_name_for(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parent = node.parent.nil? ? nil : qualified_name_for(node.parent)
            return nil if !node.parent.nil? && parent.nil?

            parent.nil? ? node.name.to_s : "#{parent}::#{node.name}"
          end
        end
        private_class_method :qualified_name_for
      end
    end
  end
end
