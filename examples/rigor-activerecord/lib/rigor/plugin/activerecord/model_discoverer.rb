# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Walks the configured model search paths via the plugin's
      # `IoBoundary`, parses each `.rb` file with Prism, and
      # collects class declarations whose immediate superclass is
      # one of the configured base classes.
      #
      # Returns rows the {ModelIndex} consumes:
      #
      #   { class_name: "User", table_name_override: nil }
      #   { class_name: "ApplicationRecord", table_name_override: "people" }
      #
      # Limitations (intentional for v0.1.0 of the plugin):
      #
      # - Only direct-superclass matches. `class Admin < User`
      #   where `User < ApplicationRecord` is NOT discovered.
      #   Add `Admin` to the index by listing every concrete model
      #   you want recognised, or add `User` to
      #   `model_base_classes` config.
      # - `self.table_name = "..."` recognised only when the RHS
      #   is a String literal. Computed names
      #   (`self.table_name = "#{tenant}_users"`) are skipped.
      # - Modules (`class Admin::User < ApplicationRecord`) are
      #   recognised; the resulting class name is the lexical
      #   path (`Admin::User`).
      class ModelDiscoverer
        # @param io_boundary [Rigor::Plugin::IoBoundary]
        # @param search_paths [Array<String>] absolute or
        #   project-relative paths.
        # @param base_classes [Array<String>] superclass names that
        #   identify a class as an AR model.
        def initialize(io_boundary:, search_paths:, base_classes:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          @base_classes = base_classes.to_set
        end

        # @return [Array<Hash>] rows of { class_name:, table_name_override: }
        def discover
          rows = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_classes(tree, []) do |class_name, table_override, associations, enums, scopes, validations, callbacks|
              rows << {
                class_name: class_name,
                table_name_override: table_override,
                associations: associations,
                enums: enums,
                scopes: scopes,
                validations: validations,
                callbacks: callbacks
              }
            end
          end
          rows
        end

        private

        def read_safely(path)
          @io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        def ruby_files_under(roots)
          roots.flat_map do |root|
            absolute = File.expand_path(root)
            next [] unless File.directory?(absolute)

            Dir.glob(File.join(absolute, "**", "*.rb"))
          end
        end

        def walk_for_classes(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode
            visit_class(node, lexical_path, &)
          when Prism::ModuleNode
            visit_module(node, lexical_path, &)
          else
            node.compact_child_nodes.each { |child| walk_for_classes(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = (lexical_path + [class_local_name]).join("::")
          superclass = constant_path_name(node.superclass) if node.superclass

          if superclass && @base_classes.include?(superclass)
            table_override = lookup_table_name_override(node.body)
            associations = lookup_associations(node.body)
            enums = lookup_enums(node.body)
            scopes = lookup_scopes(node.body)
            validations = lookup_validations(node.body)
            callbacks = lookup_callbacks(node.body)
            yield full_name, table_override, associations, enums, scopes, validations, callbacks
          end

          # Recurse into the body in case nested classes exist.
          inner_path = lexical_path + [class_local_name]
          walk_for_classes(node.body, inner_path, &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = lexical_path + [module_local_name]
          walk_for_classes(node.body, inner_path, &) if node.body
        end

        # Renders a constant-path node (`Admin::User`,
        # `::ApplicationRecord`) as a String. Returns nil for
        # shapes the discoverer chooses not to handle.
        def constant_path_name(node)
          return nil if node.nil?

          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil
              "::#{parts.join('::')}"
            when Prism::ConstantReadNode
              "#{current.name}::#{parts.join('::')}"
            end
          end
        end

        # Looks for `self.table_name = "..."` at the top level of
        # the class body. Returns the literal String when found,
        # nil otherwise.
        def lookup_table_name_override(body)
          return nil if body.nil?

          body.compact_child_nodes.each do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :table_name=
            next unless node.receiver.is_a?(Prism::SelfNode)

            arg = node.arguments&.arguments&.first
            return arg.unescaped if arg.is_a?(Prism::StringNode)
          end
          nil
        end

        # Recognised single-instance ("`belongs_to` / `has_one`")
        # and collection ("`has_many`") association DSL methods.
        # The kind drives the eventual return-type contribution:
        # singular associations narrow to `Nominal[Target] | nil`,
        # plural ones currently degrade to the RBS envelope
        # (relation types are a future track).
        ASSOCIATION_METHODS = {
          belongs_to: :singular,
          has_one: :singular,
          has_many: :collection
        }.freeze
        private_constant :ASSOCIATION_METHODS

        # Walks the class body for association DSL calls and
        # returns a list of rows shaped:
        #
        #     { name: "user", kind: :singular, target: "User" }
        #
        # The `target` is resolved from an explicit
        # `class_name: "Foo"` option when supplied, otherwise
        # inferred from the association name via
        # {Inflector.classify}. Calls whose first arg is not a
        # Symbol literal (or whose `class_name:` is a non-literal
        # expression) decline rather than guess.
        def lookup_associations(body)
          return [] if body.nil?

          rows = []
          body.compact_child_nodes.each do |node|
            next unless node.is_a?(Prism::CallNode)

            kind = ASSOCIATION_METHODS[node.name]
            next if kind.nil?
            next if node.receiver # skip `self.has_many` and similar

            row = build_association_row(node, kind)
            rows << row unless row.nil?
          end
          rows
        end

        def build_association_row(node, kind)
          args = node.arguments&.arguments
          return nil if args.nil? || args.empty?

          name_node = args.first
          return nil unless name_node.is_a?(Prism::SymbolNode)

          name = name_node.unescaped
          override = explicit_class_name(args)
          target = override || Inflector.classify(name)
          return nil if target.nil? || target.empty?

          { name: name, kind: kind, target: target }
        end

        def explicit_class_name(args)
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |pair|
              next unless pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode)
              next unless pair.key.unescaped == "class_name"
              next unless pair.value.is_a?(Prism::StringNode)

              return pair.value.unescaped
            end
          end
          nil
        end

        # `enum status: { active: 0, archived: 1 }` (Rails ≤6)
        # and `enum :status, [:active, :archived]` (Rails 7+).
        # Returns `Hash<column_name => Array<Symbol>>`.
        # Non-literal forms decline rather than guess.
        def lookup_enums(body)
          return {} if body.nil?

          enums = {}
          body.compact_child_nodes.each do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :enum
            next if node.receiver

            row = parse_enum_call(node)
            next if row.nil?

            enums[row[:column]] = row[:values]
          end
          enums.freeze
        end

        def parse_enum_call(node)
          args = node.arguments&.arguments
          return nil if args.nil? || args.empty?

          first = args.first
          if first.is_a?(Prism::SymbolNode) && args.size >= 2
            values = enum_values_from(args[1])
            return nil if values.nil?

            { column: first.unescaped, values: values }
          elsif first.is_a?(Prism::KeywordHashNode)
            entry = first.elements.find { |e| e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode) }
            return nil if entry.nil?

            values = enum_values_from(entry.value)
            return nil if values.nil?

            { column: entry.key.unescaped, values: values }
          end
        end

        def enum_values_from(node)
          case node
          when Prism::ArrayNode
            symbols = node.elements.filter_map { |e| e.unescaped if e.is_a?(Prism::SymbolNode) }
            return nil if symbols.size != node.elements.size

            symbols
          when Prism::HashNode
            node.elements.filter_map do |e|
              next nil unless e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode)

              e.key.unescaped
            end
          end
        end

        # `scope :active, -> { ... }`. Records the scope name
        # only (the body is intentionally NOT introspected —
        # scopes return ActiveRecord::Relation, which Rigor
        # doesn't carry a precise type for yet).
        def lookup_scopes(body)
          return [] if body.nil?

          scopes = []
          body.compact_child_nodes.each do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :scope
            next if node.receiver

            args = node.arguments&.arguments
            next if args.nil? || args.empty?

            name_node = args.first
            next unless name_node.is_a?(Prism::SymbolNode)

            scopes << name_node.unescaped
          end
          scopes.freeze
        end

        # `validates :name, presence: true, length: { maximum: 100 }`.
        # Records the attribute name (the validator option set
        # is ignored — the value here is the diagnostic
        # `validates :unknown_attr` surfacing when the attribute
        # isn't a column on the table).
        def lookup_validations(body)
          return [] if body.nil?

          attrs = []
          body.compact_child_nodes.each do |node|
            next unless node.is_a?(Prism::CallNode) &&
                        %i[validates validates_presence_of validates_length_of
                           validates_format_of validates_uniqueness_of].include?(node.name)
            next if node.receiver

            attrs.concat(symbol_args(node))
          end
          attrs.uniq.freeze
        end

        # `before_save :foo`, `after_create :bar`, etc. Records
        # the referenced method name (a Symbol literal). The
        # diagnostic value is "did you forget to `def` this?".
        # Block callbacks (`before_save { ... }`) decline.
        CALLBACK_METHODS = %i[
          before_validation after_validation
          before_save after_save around_save
          before_create after_create around_create
          before_update after_update around_update
          before_destroy after_destroy around_destroy
          after_commit after_rollback
          after_initialize after_find
        ].freeze
        private_constant :CALLBACK_METHODS

        def lookup_callbacks(body)
          return [] if body.nil?

          targets = []
          body.compact_child_nodes.each do |node|
            next unless node.is_a?(Prism::CallNode)
            next unless CALLBACK_METHODS.include?(node.name)
            next if node.receiver

            symbol_args(node).each do |name|
              targets << { name: name, callback: node.name.to_s }
            end
          end
          targets.freeze
        end

        # Collects every Symbol-literal positional argument
        # from a CallNode. Used by both `lookup_validations`
        # and `lookup_callbacks` to extract the attribute /
        # method name list.
        def symbol_args(node)
          args = node.arguments&.arguments
          return [] if args.nil?

          args.filter_map { |arg| arg.unescaped if arg.is_a?(Prism::SymbolNode) }
        end
      end
    end
  end
end
