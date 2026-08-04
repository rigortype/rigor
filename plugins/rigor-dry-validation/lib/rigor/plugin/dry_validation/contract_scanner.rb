# frozen_string_literal: true

require "prism"
require "rigor/source/literals"

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

        # `dry-validation.rule-key-mismatch` (issue #137's remaining ceiling checkbox) — walks an
        # ALREADY-PARSED file's root node collecting `{node:, key:, contract_fqn:}` issues for a
        # `rule(:sym, ...) do ... end` call whose Symbol argument names a key that is NOT in the
        # Contract's OWN, cleanly-recognised `params`/`json` key set.
        #
        # FP-gated hard, per two independent all-or-nothing checks:
        #
        # - {#clean_known_keys} — the Contract's key universe is trusted ONLY when EVERY top-level
        #   statement in EVERY `params`/`json` block is a recognised `required`/`optional` row (typed or
        #   not — an unmodelled row is still a DECLARED key) or the inert `config.<x> = <literal>` idiom.
        #   A loop building keys dynamically, a splat, an `include`, a nested schema merge, or a
        #   `params`/`json(SomeSchema)` delegating to an externally-shared schema — ANY of these makes
        #   the WHOLE Contract's key universe untrustworthy, not just the offending row, and the
        #   Contract is skipped outright (no diagnostic against any of its `rule()` calls).
        # - {#rule_arguments_or_nil} — a `rule(...)` call is checked ONLY when EVERY argument is a
        #   literal Symbol. A splat (`rule(*keys)`), a String, a local variable, or a Hash (the
        #   nested-key form `rule(user: [:name])`) makes the WHOLE call unresolvable, not just that one
        #   argument, and it is skipped rather than partially validated.
        #
        # Returns `[]` immediately, without touching a single file, when `rigor-dry-schema` isn't loaded
        # — there is no key universe to check a `rule()` call against without it.
        def rule_key_issues(root, type_aliases)
          return [] unless Rigor::Plugin.registered_for("dry-schema")

          issues = []
          walk_for_rule_issues(root, [], type_aliases, issues)
          issues
        end

        def walk_for_rule_issues(node, qualified_prefix, type_aliases, issues)
          return if node.nil?

          case node
          when Prism::ClassNode
            inner_name = constant_name_for(node.constant_path)
            return if inner_name.nil?

            new_prefix = qualified_prefix + [inner_name]
            check_contract_rules(node, new_prefix.join("::"), type_aliases, issues) if contract_subclass?(node)
            walk_for_rule_issues(node.body, new_prefix, type_aliases, issues)
          when Prism::ModuleNode
            inner_name = constant_name_for(node.constant_path)
            return if inner_name.nil?

            walk_for_rule_issues(node.body, qualified_prefix + [inner_name], type_aliases, issues)
          else
            node.compact_child_nodes.each { |child| walk_for_rule_issues(child, qualified_prefix, type_aliases, issues) }
          end
        end
        private_class_method :walk_for_rule_issues

        def check_contract_rules(class_node, contract_fqn, type_aliases, issues)
          body = class_node.body
          return if body.nil?

          children = body.is_a?(Prism::StatementsNode) ? body.body : [body]
          known_keys = clean_known_keys(children, type_aliases)
          return if known_keys.nil?

          children.each do |child|
            next unless rule_call?(child)

            check_rule_call(child, contract_fqn, known_keys, issues)
          end
        end
        private_class_method :check_contract_rules

        # The Contract's full declared key set (required + optional + unmodelled, across BOTH `params`
        # and `json` if both are present — a Contract having both is unusual, so the conservative read
        # is the union rather than guessing which one a given `rule()` targets), or nil when the
        # Contract has no `params`/`json` block at all OR either block fails {#clean_schema_block?}.
        def clean_known_keys(children, type_aliases)
          blocks = children.select { |c| bare_block_call?(c) && %i[params json].include?(c.name) }
          return nil if blocks.empty?

          keys = Set.new
          blocks.each do |block_call|
            return nil unless clean_schema_block?(block_call.block)

            shape = DrySchema::SchemaScanner.collect_schema_shape(block_call.block, type_aliases, nested: false)
            keys.merge(shape[:required].keys)
            keys.merge(shape[:optional].keys)
            keys.merge(shape[:unmodelled][:required])
            keys.merge(shape[:unmodelled][:optional])
          end
          keys
        end
        private_class_method :clean_known_keys

        def clean_schema_block?(block_node)
          body = block_node.body
          return true if body.nil? # empty block — vacuously clean, contributes no keys

          children = body.is_a?(Prism::StatementsNode) ? body.body : [body]
          children.all? { |child| required_or_optional_row?(child) || inert_config_assignment?(child) }
        end
        private_class_method :clean_schema_block?

        # A `required(:key)...` / `optional(:key)...` chain, ANY predicate suffix (even one this
        # scanner can't type — an unmodelled row is still a row that DECLARES the key, which is all
        # {#clean_known_keys} needs).
        def required_or_optional_row?(node)
          return false unless node.is_a?(Prism::CallNode)

          current = node
          while current.is_a?(Prism::CallNode)
            if %i[required optional].include?(current.name)
              return !Rigor::Source::Literals.symbol(current.arguments&.arguments&.first).nil?
            end

            current = current.receiver
          end
          false
        end
        private_class_method :required_or_optional_row?

        # `config.validate_keys = true` and similar — dry-schema's own `config.<x> = <literal>` idiom.
        # Declares no key, so it's safe to ignore rather than treat as "unrecognised" (over-declining a
        # perfectly common line would silently drop valid diagnostics, not risk a false positive, but
        # there's no reason to pay that cost).
        def inert_config_assignment?(node)
          node.is_a?(Prism::CallNode) && node.name.end_with?("=") &&
            node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :config && node.receiver.receiver.nil?
        end
        private_class_method :inert_config_assignment?

        def rule_call?(node)
          node.is_a?(Prism::CallNode) && node.name == :rule && node.receiver.nil? && node.block.is_a?(Prism::BlockNode)
        end
        private_class_method :rule_call?

        def check_rule_call(rule_node, contract_fqn, known_keys, issues)
          symbols = rule_arguments_or_nil(rule_node)
          return if symbols.nil?

          symbols.each do |arg|
            key = arg.unescaped.to_sym
            next if known_keys.include?(key)

            issues << { node: arg, key: key, contract_fqn: contract_fqn, known_keys: known_keys }
          end
        end
        private_class_method :check_rule_call

        # Every positional argument of `rule(...)`, as `Prism::SymbolNode`s, or nil when there are none,
        # or ANY of them isn't a literal Symbol (a splat, a String, a local variable, or a Hash — the
        # `rule(user: [:name])` nested-key form). One non-Symbol argument makes the WHOLE call
        # unresolvable, not just that argument.
        def rule_arguments_or_nil(rule_node)
          args = rule_node.arguments&.arguments
          return nil if args.nil? || args.empty?
          return nil unless args.all?(Prism::SymbolNode)

          args
        end
        private_class_method :rule_arguments_or_nil

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
