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
        # from the upstream gem.
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

        # Slice 2 — nested-category aliases. dry-types installs
        # four parallel coercion categories: `Coercible::*`
        # (everything-to-target coercion), `Strict::*` (no
        # coercion; raise if mismatch), `Params::*` (HTTP /
        # query-string-style coercion, used by Hanami / Roda /
        # dry-web in request handling), `JSON::*` (JSON-shape
        # coercion). Each category exposes the same set of names
        # as the canonical shortcuts above, plus a few additions
        # that are category-specific (`Params::Nil`,
        # `JSON::Symbol`). For Rigor's purposes the underlying
        # class is the same regardless of category — coercion
        # semantics are a runtime concern. We register every
        # `<module>::<Category>::<Name>` mapping the upstream gem
        # publishes so call-site references work uniformly.
        NESTED_CATEGORIES = %w[Coercible Strict Params JSON].freeze
        private_constant :NESTED_CATEGORIES

        module_function

        # @param paths [Array<String>] absolute paths to `.rb`
        #   files the project's `paths:` resolves to.
        # @return [Hash{String => String}] frozen
        #   `{aliased_name => underlying_class_name}` map. Empty
        #   when no `include Dry.Types()` declaration is found.
        def scan(paths:)
          results = paths.flat_map { |path| scan_file(path) }
          modules = results.map { |r| r[:module_name] }.uniq
          return {}.freeze if modules.empty?

          base = canonical_table(modules)
          results.each do |result|
            result[:compositions].each do |const_name, underlying|
              # Each result's compositions are scoped under that
              # result's enclosing module (`Types::Email`, etc.).
              base["#{result[:module_name]}::#{const_name}"] ||= underlying
            end
          end
          base.freeze
        end

        # Populates the canonical-shortcut + nested-category
        # table (15 + 15 × 4 = 75 entries per alias module).
        def canonical_table(modules)
          modules.each_with_object({}) do |module_name, acc|
            CANONICAL_ALIASES.each do |alias_name, underlying|
              acc["#{module_name}::#{alias_name}"] = underlying
              NESTED_CATEGORIES.each do |category|
                acc["#{module_name}::#{category}::#{alias_name}"] = underlying
              end
            end
          end
        end
        private_class_method :canonical_table

        def scan_file(path)
          source = File.read(path)
          parse_result = Prism.parse(source, filepath: path)
          return [] unless parse_result.errors.empty?

          collect_alias_modules(parse_result.value, []).map do |module_info|
            compositions = collect_compositions(module_info[:body])
            { module_name: module_info[:module_name], compositions: compositions }
          end
        rescue StandardError
          # Missing-file / parse failures degrade to "no
          # contribution from this file"; the plugin's
          # user-visible surface is the published fact, and
          # dropping unparseable files keeps the fact stable.
          []
        end
        private_class_method :scan_file

        # Walks a Prism AST collecting alias-module info:
        # `{module_name:, body:}` for every `module X; include
        # Dry.Types(); …end` shape. Tracks the enclosing module
        # chain so a nested `module App; module Types; include
        # Dry.Types(); end; end` publishes `"App::Types"` as the
        # alias scope. The `body:` field is the
        # `Prism::StatementsNode` (or nil) we re-walk later for
        # user-authored compositions (slice 3).
        def collect_alias_modules(node, qualified_prefix)
          return [] unless node.is_a?(Prism::Node)

          case node
          when Prism::ModuleNode
            name = qualified_name_for(node.constant_path)
            new_prefix = name ? qualified_prefix + [name] : qualified_prefix
            children = node.body ? collect_alias_modules(node.body, new_prefix) : []
            current = if name && contains_dry_types_include?(node.body)
                        [{ module_name: new_prefix.join("::"), body: node.body }]
                      else
                        []
                      end
            current + children
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

        # Slice 3 — user-authored composition recognition.
        # Walks the alias-module body for `Email =
        # String.constrained(...)` shapes. Each
        # `ConstantWriteNode` whose RHS is a method chain
        # rooted on a canonical-shortcut name (`String`,
        # `Integer`, …) — or on a nested-category form
        # (`Strict::String` etc.) — registers the LHS under
        # the canonical head's underlying class. Unions
        # (`String | Integer`) and intersections are skipped
        # (no single underlying class); transitive references
        # to other compositions (`ManagerEmail = Email`) are
        # also skipped at the floor (no two-pass resolution
        # yet).
        def collect_compositions(body)
          return {} if body.nil?

          compositions = {}
          tree_walk(body).each do |child|
            next unless child.is_a?(Prism::ConstantWriteNode)

            head = composition_head_canonical(child.value)
            next if head.nil?

            compositions[child.name.to_s] = CANONICAL_ALIASES.fetch(head)
          end
          compositions
        end
        private_class_method :collect_compositions

        # Walks an RHS expression looking for the canonical
        # shortcut name at the root of a method chain. Returns
        # the canonical name (`"String"` etc.) or nil.
        #
        # Recognised shapes (recursively on `node.receiver`):
        #
        # - Bare `String` / `Integer` — `Prism::ConstantReadNode`
        #   whose name is in `CANONICAL_ALIASES`.
        # - `Strict::String` / `Coercible::Integer` / etc. —
        #   `Prism::ConstantPathNode` whose tail is in
        #   `CANONICAL_ALIASES`.
        # - `String.constrained(...)` / `.optional` /
        #   `.default(...)` / arbitrary single-arg method —
        #   recurse on the receiver.
        #
        # Declines on `String | Integer` (union, `:|`) and
        # `String & Foo` (intersection, `:&`) so the alias
        # table doesn't claim a single underlying class for
        # a multi-class composition.
        def composition_head_canonical(node)
          case node
          when Prism::ConstantReadNode
            CANONICAL_ALIASES.key?(node.name.to_s) ? node.name.to_s : nil
          when Prism::ConstantPathNode
            tail = node.name.to_s
            CANONICAL_ALIASES.key?(tail) ? tail : nil
          when Prism::CallNode
            return nil if %i[| &].include?(node.name)
            return nil if node.receiver.nil?

            composition_head_canonical(node.receiver)
          end
        end
        private_class_method :composition_head_canonical

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
