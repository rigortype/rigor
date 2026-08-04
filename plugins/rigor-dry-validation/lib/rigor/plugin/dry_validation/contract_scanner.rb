# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class DryValidation < Rigor::Plugin::Base
      # Walks project source for `class T < Dry::Validation::Contract` subclasses and returns the
      # contract class FQN set.
      #
      # Recognition tightness: the superclass match accepts EITHER the fully-qualified
      # `Dry::Validation::Contract` (3-segment path) OR the lexical-nested `Validation::Contract`
      # (2-segment path, when the class body lives inside `module Dry`). The bare `< Contract` form
      # (1-segment) is NOT recognised — too ambiguous; users who deeply nest under `Dry::Validation`
      # should use the explicit form. Unrelated `< MyApp::Validation::Contract` shapes with the same tail
      # do NOT register.
      module ContractScanner
        CONTRACT_FULL_PATH = %w[Dry Validation Contract].freeze
        CONTRACT_LEXICAL_DRY_PATH = %w[Validation Contract].freeze
        private_constant :CONTRACT_FULL_PATH, :CONTRACT_LEXICAL_DRY_PATH

        module_function

        # @param paths [Array<String>] absolute paths to `.rb` files the project's `paths:` resolves to.
        # @return [Array<String>] frozen, sorted list of recognized contract class FQNs (e.g.
        #   `["App::NewUserContract", "Types::EmailContract"]`).
        def scan(paths:)
          contracts = []
          paths.each { |path| contracts.concat(scan_file(path)) }
          contracts.uniq.sort.freeze
        end

        def scan_file(path)
          source = File.read(path)
          parse_result = Prism.parse(source, filepath: path)
          return [] unless parse_result.errors.empty?

          collect_contracts(parse_result.value, [])
        rescue StandardError
          []
        end
        private_class_method :scan_file

        # Issue #137 slices 2/3 — per-Contract `params { ... }` / `json { ... }` shapes, delegating the
        # actual required/optional walk to `rigor-dry-schema`'s {DrySchema::SchemaScanner.collect_schema_shape}
        # (the SAME dry-schema DSL, just under a bare `params`/`json` call instead of
        # `Dry::Schema.Params { ... }`). Returns `{}` immediately, without touching a single file, when
        # `rigor-dry-schema` isn't loaded — the companion plugin's absence is a hard precondition here,
        # not a degrade-gracefully fallback, because this plugin ships no required/optional walker of
        # its own.
        #
        # @return [Hash{String => Hash{Symbol => Hash}}] contract FQN => `{params: <shape>}` and/or
        #   `{json: <shape>}` (only the recognised key(s) are present; a contract with neither present
        #   contributes nothing). Each `<shape>` is exactly {DrySchema::SchemaScanner.collect_schema_shape}'s
        #   `{required:, optional:, unmodelled:}` return.
        def scan_schema_blocks(paths:, type_aliases: {})
          return {} unless Rigor::Plugin.registered_for("dry-schema")

          table = {}
          paths.each do |path|
            scan_file_schema_blocks(path, type_aliases).each do |fqn, shapes|
              table[fqn] ||= shapes
            end
          end
          table.freeze
        end

        def scan_file_schema_blocks(path, type_aliases)
          source = File.read(path)
          parse_result = Prism.parse(source, filepath: path)
          return {} unless parse_result.errors.empty?

          collect_params_blocks(parse_result.value, [], type_aliases)
        rescue StandardError
          {}
        end
        private_class_method :scan_file_schema_blocks

        # Mirrors {#collect_contracts}'s recursive shape, additionally capturing each recognised
        # Contract's own `params { ... }` / `json { ... }` shape.
        def collect_params_blocks(node, qualified_prefix, type_aliases)
          return {} if node.nil?

          case node
          when Prism::ClassNode
            collect_class_params_blocks(node, qualified_prefix, type_aliases)
          when Prism::ModuleNode
            inner_name = constant_name_for(node.constant_path)
            return {} if inner_name.nil?

            collect_params_blocks(node.body, qualified_prefix + [inner_name], type_aliases)
          else
            node.compact_child_nodes.each_with_object({}) do |child, acc|
              collect_params_blocks(child, qualified_prefix, type_aliases).each { |k, v| acc[k] ||= v }
            end
          end
        end
        private_class_method :collect_params_blocks

        def collect_class_params_blocks(node, qualified_prefix, type_aliases)
          inner_name = constant_name_for(node.constant_path)
          return {} if inner_name.nil?

          new_prefix = qualified_prefix + [inner_name]
          inner = collect_params_blocks(node.body, new_prefix, type_aliases)

          if contract_subclass?(node)
            shapes = class_body_schema_shapes(node.body, type_aliases)
            inner[new_prefix.join("::")] = shapes unless shapes.empty?
          end
          inner
        end
        private_class_method :collect_class_params_blocks

        # ONLY a top-level `params do ... end` / `json do ... end` call directly inside the Contract's
        # class body — a bare call, no receiver, no positional/keyword arguments, exactly one block.
        # A call nested inside a conditional, a method def, or wrapped in any other construct is NOT
        # this floor; it's indistinguishable here from a dynamically-built or externally-shared schema,
        # and the conservative read is to contribute nothing rather than guess.
        def class_body_schema_shapes(body, type_aliases)
          return {} if body.nil?

          children = body.is_a?(Prism::StatementsNode) ? body.body : [body]
          shapes = {}
          children.each do |child|
            next unless bare_block_call?(child)

            case child.name
            when :params then shapes[:params] ||= DrySchema::SchemaScanner.collect_schema_shape(child.block, type_aliases, nested: false)
            when :json then shapes[:json] ||= DrySchema::SchemaScanner.collect_schema_shape(child.block, type_aliases, nested: false)
            end
          end
          shapes
        end
        private_class_method :class_body_schema_shapes

        def bare_block_call?(node)
          node.is_a?(Prism::CallNode) && node.receiver.nil? && node.arguments.nil? &&
            node.block.is_a?(Prism::BlockNode)
        end
        private_class_method :bare_block_call?

        def collect_contracts(node, qualified_prefix)
          return [] if node.nil?

          case node
          when Prism::ClassNode then collect_class_node(node, qualified_prefix)
          when Prism::ModuleNode then collect_module_node(node, qualified_prefix)
          else
            node.compact_child_nodes.flat_map { |c| collect_contracts(c, qualified_prefix) }
          end
        end
        private_class_method :collect_contracts

        def collect_class_node(node, qualified_prefix)
          inner_name = constant_name_for(node.constant_path)
          return [] if inner_name.nil?

          new_prefix = qualified_prefix + [inner_name]
          inner = collect_contracts(node.body, new_prefix)
          inner += [new_prefix.join("::")] if contract_subclass?(node)
          inner
        end
        private_class_method :collect_class_node

        def collect_module_node(node, qualified_prefix)
          inner_name = constant_name_for(node.constant_path)
          return [] if inner_name.nil?

          collect_contracts(node.body, qualified_prefix + [inner_name])
        end
        private_class_method :collect_module_node

        # Matches superclasses whose constant chain is EXACTLY `Dry::Validation::Contract` (full path) OR
        # EXACTLY `Validation::Contract` (lexical-Dry path). Other shapes — including
        # same-tail-but-different-root chains and the ambiguous bare `Contract` — do not match.
        def contract_subclass?(class_node)
          superclass = class_node.superclass
          return false if superclass.nil?

          path = constant_path_segments(superclass)
          [CONTRACT_FULL_PATH, CONTRACT_LEXICAL_DRY_PATH].include?(path)
        end
        private_class_method :contract_subclass?

        def constant_path_segments(node)
          case node
          when Prism::ConstantReadNode then [node.name.to_s]
          when Prism::ConstantPathNode
            segments = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              segments.unshift(current.name.to_s)
              current = current.parent
            end
            segments.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
            segments
          else
            []
          end
        end
        private_class_method :constant_path_segments

        def constant_name_for(node)
          segments = constant_path_segments(node)
          segments.empty? ? nil : segments.join("::")
        end
        private_class_method :constant_name_for
      end
    end
  end
end
