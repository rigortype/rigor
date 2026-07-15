# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"
require "rigor/source/literals"

require_relative "factory_index"

module Rigor
  module Plugin
    class Factorybot < Rigor::Plugin::Base
      # Walks `factory_search_paths` and parses each `.rb` file into a {FactoryIndex}. The search-path
      # list contains both directory paths (recursively walked) and direct file paths (read once); the
      # typical default `["spec/factories", "spec/factories.rb"]` covers both the multi-file convention
      # RSpec uses today and the legacy single-file form.
      #
      # The walker recognises:
      #
      # - `factory :users do ... end` — symbol form
      # - `factory "users" do ... end` — string form
      # - `factory :users, aliases: [:author] do ... end` — alias form
      #
      # Inside a factory block, attribute declarations come in several shapes. Only literal-name forms
      # are recognised (Symbol arg / String arg):
      #
      # - `name { "Alice" }` — implicit attribute via `method_missing` with a block (FactoryBot's modern
      #   syntax)
      # - `name "Alice"` — implicit attribute via `method_missing` with a positional argument (legacy)
      # - `add_attribute(:name) { "Alice" }` — the explicit form
      #
      # Sequences (`sequence(:email) { ... }`), associations (`association :author`), traits, and parent
      # / child relationships are deferred to later slices.
      class FactoryDiscoverer
        def initialize(io_boundary:, search_paths:)
          @io_boundary = io_boundary
          @search_paths = search_paths
        end

        # @return [FactoryIndex]
        def discover
          entries = {}
          ruby_files_under(@search_paths).each do |path|
            harvest(path, entries)
          end
          FactoryIndex.new(entries.freeze)
        end

        private

        def ruby_files_under(roots)
          roots.flat_map do |root|
            absolute = File.expand_path(root)
            if File.file?(absolute)
              [absolute]
            elsif File.directory?(absolute)
              Dir.glob(File.join(absolute, "**", "*.rb"))
            else
              []
            end
          end
        end

        def harvest(path, entries)
          contents = @io_boundary.read_file(path)
          parse_result = Prism.parse(contents)
          return unless parse_result.errors.empty?

          walk_for_factories(parse_result.value) do |factory_name, attribute_names, model_class|
            entries[factory_name] = FactoryIndex::Entry.new(
              name: factory_name,
              attribute_names: attribute_names.uniq.freeze,
              model_class: model_class
            )
          end
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        # Yields `(factory_name, [attribute_names])` for every `factory :name do ... end` call
        # discovered in the subtree. The walker recurses into top-level wrapping blocks
        # (`FactoryBot.define do ... end`) and into arbitrary container nodes so factories inside
        # `module` / `class` blocks are still picked up.
        def walk_for_factories(node, &)
          return unless node.is_a?(Prism::Node)

          if factory_call?(node)
            visit_factory(node, &)
            return
          end
          node.rigor_each_child { |child| walk_for_factories(child, &) }
        end

        def factory_call?(node)
          node.is_a?(Prism::CallNode) && node.name == :factory && node.receiver.nil?
        end

        def visit_factory(call_node)
          factory_name = literal_name_arg(call_node)
          return if factory_name.nil?

          attribute_names = collect_attribute_names(call_node.block)
          model_class = factory_model_class(call_node, factory_name)
          yield factory_name, attribute_names, model_class
        end

        def literal_name_arg(call_node)
          Rigor::Source::Literals.symbol_or_string_name(call_node.arguments&.arguments&.first)
        end

        # Resolves the model class name for the factory. Three sources, in priority order:
        #
        # 1. Explicit `class: <Const>` keyword arg — ConstantReadNode / ConstantPathNode value.
        # 2. Explicit `class: "<name>"` keyword arg — String value (supports `"Admin::User"`).
        # 3. Inflected from the factory name — `:user` → `"User"`, `:admin_user` → `"AdminUser"`. The
        #    factory name is already singular by FactoryBot convention, so we only need camelization.
        #
        # Returns a String (the canonical class name).
        def factory_model_class(call_node, factory_name)
          explicit = explicit_class_option(call_node)
          return explicit if explicit

          # ADR-39: the real ActiveSupport::Inflector camelizes the factory name to its class
          # (`admin_user` → `AdminUser`, `admin/user` → `Admin::User`), so the model-class fallback
          # matches Rails' real convention rather than an approximation.
          Rigor::Plugin::Inflector.camelize(factory_name)
        end

        def explicit_class_option(call_node)
          kwargs = factory_keyword_args(call_node)
          return nil if kwargs.nil?

          class_pair = kwargs.elements.find do |elem|
            elem.is_a?(Prism::AssocNode) &&
              Source::Literals.symbol_named?(elem.key, "class")
          end
          return nil if class_pair.nil?

          render_class_value(class_pair.value)
        end

        def factory_keyword_args(call_node)
          args = call_node.arguments&.arguments || []
          last = args.last
          last.is_a?(Prism::KeywordHashNode) || last.is_a?(Prism::HashNode) ? last : nil
        end

        def render_class_value(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then render_constant_path(node)
          when Prism::StringNode then node.unescaped
          end
        end

        def render_constant_path(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          case current
          when nil then "::#{parts.join('::')}"
          when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
          end
        end

        def collect_attribute_names(block_node)
          return [] unless block_node.is_a?(Prism::BlockNode)

          attributes = []
          collect_attributes_from(block_node.body, attributes)
          attributes
        end

        # Walks the block body collecting attribute names. Only top-level statements are examined —
        # attributes inside `trait :admin do ... end` or other nested blocks are not collected (traits
        # deferred to a follow-up).
        def collect_attributes_from(node, accumulator)
          return unless node.is_a?(Prism::Node)

          if node.is_a?(Prism::StatementsNode)
            node.body.each { |stmt| record_attribute(stmt, accumulator) }
          else
            record_attribute(node, accumulator)
          end
        end

        def record_attribute(node, accumulator)
          return unless node.is_a?(Prism::CallNode) && node.receiver.nil?
          # Skip association / sequence / trait / framework methods — only plain attribute declarations
          # are recorded.
          return if SKIPPED_METHODS.include?(node.name)

          name = if node.name == :add_attribute
                   literal_name_arg(node)
                 else
                   # method_missing form: the call's method name IS the attribute name.
                   node.name.to_s
                 end
          accumulator << name if name
        end

        SKIPPED_METHODS = %i[
          association sequence trait traits initialize_with
          factory after before to_create skip_create
        ].freeze
        private_constant :SKIPPED_METHODS
      end
    end
  end
end
