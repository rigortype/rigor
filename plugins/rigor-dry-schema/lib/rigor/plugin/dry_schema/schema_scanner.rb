# frozen_string_literal: true

require "prism"
require "rigor/source/literals"

module Rigor
  module Plugin
    class DrySchema < Rigor::Plugin::Base
      # Walks project source for `Foo = Dry::Schema.{Params,JSON,define} { ... }` shapes and emits a
      # `{schema_const_fqn => {required: {key => underlying_class}, optional: {…}}}` table covering each
      # schema's typed-key surface.
      module SchemaScanner
        # The dry-schema canonical-type symbols accepted as predicate arguments. Maps each to the
        # underlying Ruby class name (the same vocabulary `rigor-dry-types` uses for `CANONICAL_ALIASES`,
        # intersected with what dry-schema's predicate engine accepts).
        CANONICAL_TYPES = {
          string: "String",
          integer: "Integer",
          float: "Float",
          decimal: "BigDecimal",
          symbol: "Symbol",
          bool: "TrueClass",
          date: "Date",
          date_time: "DateTime",
          time: "Time",
          hash: "Hash",
          array: "Array"
        }.tap { |h| h[:nil] = "NilClass" }.freeze

        # The dry-schema predicate verbs that accept a type argument. Each verb has a slightly different
        # runtime semantic (`filled` = present + non-empty; `value` = present; `maybe` = present-or-nil;
        # `each` = collection element type) but for Rigor's purposes they all contribute the same
        # underlying class for the key.
        TYPE_BEARING_PREDICATES = %i[filled value maybe each].to_set.freeze
        private_constant :TYPE_BEARING_PREDICATES

        # The three entry-point method names on `Dry::Schema`.
        SCHEMA_ENTRY_NAMES = %i[Params JSON define].to_set.freeze
        private_constant :SCHEMA_ENTRY_NAMES

        module_function

        # @param paths [Array<String>] absolute paths to `.rb` files the project's `paths:` resolves to.
        # @param type_aliases [Hash{String => String}] the ADR-9 `:dry_type_aliases` fact published by
        #   `rigor-dry-types` when loaded. Used to resolve `value(Types::Email)` references to their
        #   underlying class. Empty when the plugin isn't loaded.
        # @return [Hash{String => Hash{Symbol => Hash{Symbol => String}}}] frozen per-schema typed-key
        #   table. Empty when no recognisable schema declaration is found.
        def scan(paths:, type_aliases: {})
          table = {}
          paths.each do |path|
            scan_file(path, type_aliases).each do |schema_const, shape|
              table[schema_const] ||= shape
            end
          end
          table.freeze
        end

        def scan_file(path, type_aliases)
          source = File.read(path)
          parse_result = Prism.parse(source, filepath: path)
          return {} unless parse_result.errors.empty?

          collect_schemas(parse_result.value, [], type_aliases)
        rescue StandardError
          {}
        end
        private_class_method :scan_file

        # Per-row `dry-schema.unknown-type` diagnostics (ceiling slice, issue #137). Walks an
        # ALREADY-PARSED file's root node — the engine parses every analysed file once, so this reuses
        # that AST rather than re-reading and re-parsing the file — collecting `{node:, key:, symbol:}`
        # issues for a `required(:key).<verb>(:sym)` / `optional(:key).<verb>(:sym)` row whose
        # type-bearing predicate (`filled` / `value` / `maybe` / `each`) receives a literal Symbol argument
        # OUTSIDE `CANONICAL_TYPES`. Recurses into `each do ... end` nested rows (mirrors
        # {#each_block_type_info}) so a nested row's bad symbol is caught too.
        #
        # A Constant argument (`value(Types::Email)`) is never flagged: an unresolved alias already has a
        # silent, deliberate fallback (no `:dry_type_aliases` fact, or a name the fact doesn't know) per
        # the existing slice-1 "drops constant-type references..." behaviour, and this diagnostic firing
        # on it would misfire on every entirely-correct `value(Types::Email)` row in a project that simply
        # doesn't have `rigor-dry-types` loaded.
        #
        # `dry-schema.unknown-predicate` (the OTHER ceiling diagnostic the README named) is deliberately
        # NOT implemented: distinguishing a genuinely-unrecognised predicate NAME from one of dry-schema's
        # many legitimate fine-grained predicates (`size?`, `gt?`, `format?`, `included_in?`, ...) that
        # this scanner simply doesn't model would need a complete predicate registry this plugin doesn't
        # have, and a `required(:key)` row with NO type-bearing predicate at all is itself entirely
        # legitimate dry-schema (a presence-only check). Guessing here risks flagging correct code — the
        # AGENTS.md "false positives outrank worst-case reading" call, applied by declining.
        def unknown_type_issues(root)
          issues = []
          walk_for_unknown_type(root, issues)
          issues
        end

        def walk_for_unknown_type(node, issues)
          return if node.nil?

          if node.is_a?(Prism::CallNode) && schema_entry_call?(node) && node.block
            collect_row_issues(node.block, issues)
          end
          node.compact_child_nodes.each { |child| walk_for_unknown_type(child, issues) }
        end
        private_class_method :walk_for_unknown_type

        def collect_row_issues(block_node, issues)
          body = block_node.body
          return if body.nil?

          children = body.is_a?(Prism::StatementsNode) ? body.body : [body]
          children.each { |child| visit_chain_for_issues(child, issues) }
        end
        private_class_method :collect_row_issues

        def visit_chain_for_issues(node, issues)
          return unless node.is_a?(Prism::CallNode)

          key, = extract_key_and_kind(node)
          return if key.nil?

          current = node
          while current.is_a?(Prism::CallNode)
            if current.name == :each && current.block
              collect_row_issues(nested_block_body(current.block), issues)
              return
            end
            if TYPE_BEARING_PREDICATES.include?(current.name)
              record_unknown_type_issue(current, key, issues)
              return
            end
            current = current.receiver
          end
        end
        private_class_method :visit_chain_for_issues

        def record_unknown_type_issue(call_node, key, issues)
          arg = call_node.arguments&.arguments&.first
          return unless arg.is_a?(Prism::SymbolNode)

          symbol = arg.unescaped.to_sym
          return if CANONICAL_TYPES.key?(symbol)

          issues << { node: call_node, key: key, symbol: symbol }
        end
        private_class_method :record_unknown_type_issue

        # Walks the AST collecting `<Const> = Dry::Schema.X { ... }` assignments at any nesting level.
        # Tracks the enclosing constant chain so a class-level `class Foo; SCHEMA = Dry::Schema.Params
        # { ... }; end` registers as `"Foo::SCHEMA"`.
        def collect_schemas(node, qualified_prefix, type_aliases)
          return {} if node.nil?

          case node
          when Prism::ConstantWriteNode
            collect_schema_assignment(node, qualified_prefix, type_aliases)
          when Prism::ClassNode
            inner_name = constant_name_for(node.constant_path)
            return {} if inner_name.nil?

            collect_schemas(node.body, qualified_prefix + [inner_name], type_aliases)
          when Prism::ModuleNode
            inner_name = constant_name_for(node.constant_path)
            return {} if inner_name.nil?

            collect_schemas(node.body, qualified_prefix + [inner_name], type_aliases)
          else
            node.compact_child_nodes.each_with_object({}) do |child, acc|
              collect_schemas(child, qualified_prefix, type_aliases).each do |k, v|
                acc[k] ||= v
              end
            end
          end
        end
        private_class_method :collect_schemas

        def collect_schema_assignment(node, qualified_prefix, type_aliases)
          rhs = node.value
          return {} unless schema_entry_call?(rhs)
          return {} unless rhs.is_a?(Prism::CallNode) && rhs.block

          schema_const = (qualified_prefix + [node.name.to_s]).join("::")
          shape = collect_schema_shape(rhs.block, type_aliases, nested: false)
          { schema_const => shape }
        end
        private_class_method :collect_schema_assignment

        # Matches `Dry::Schema.Params { ... }` / `Dry::Schema.JSON { ... }` / `Dry::Schema.define { ... }`.
        def schema_entry_call?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless SCHEMA_ENTRY_NAMES.include?(node.name)

          receiver = node.receiver
          receiver.is_a?(Prism::ConstantPathNode) &&
            receiver.name == :Schema &&
            receiver.parent.is_a?(Prism::ConstantReadNode) &&
            receiver.parent.name == :Dry
        end
        private_class_method :schema_entry_call?

        # PUBLIC reuse surface (issue #137 slices 2/3): `rigor-dry-validation`'s `params { ... }` /
        # `json { ... }` block body is the SAME dry-schema DSL a top-level `Dry::Schema.X { ... }` body
        # is, so that plugin delegates here instead of duplicating the required/optional walk — the
        # `docs/design/20260517-dry-validation-slicing.md` slicing note's own "delegate to
        # rigor-dry-schema's walker" option. Only reachable from another plugin when `rigor-dry-schema`
        # is registered (the caller checks `Rigor::Plugin.registered_for("dry-schema")` first — that is
        # also what makes THIS class already loaded/defined for the caller to reference).
        #
        # `nested:` is false at the top-level `Dry::Schema.X { ... }` body and true inside an `each do
        # ... end` row's own recursive call (see {#each_block_type_info}). It caps the recursion at ONE
        # level deep: with `nested: true`, {#walk_predicate_chain} declines a FURTHER `each do ... end`
        # rather than recursing again (issue #137 deliberately does not model doubly-nested arrays of
        # arrays). This also keeps `collect_schema_shape` from calling itself — {#each_block_type_info}
        # is the only caller that ever passes `nested: true}` — so the call graph has no cycle for the
        # engine's return-type inference to approximate through.
        def collect_schema_shape(block_node, type_aliases, nested:)
          required = {}
          optional = {}
          declared = { required: [], optional: [] }
          walk_block_body(block_node, type_aliases, nested) do |kind, key, type_info|
            declared[kind] << key
            (kind == :required ? required : optional)[key] = type_info if type_info
          end

          remap_aliases!(required, type_aliases)
          remap_aliases!(optional, type_aliases)

          {
            required: required.freeze,
            optional: optional.freeze,
            unmodelled: unmodelled_keys(declared, required, optional)
          }.freeze
        end

        # Walks every top-level `required(:key).<predicate>(...)` / `optional(:key).<predicate>(...)`
        # chain in the block body. The block's body is either a `Prism::StatementsNode` (multi-statement)
        # or a single expression node. `type_aliases` threads down to a nested `each do ... end` row's own
        # recursive {#collect_schema_shape} call (slice 2's alias resolution applies at every nesting
        # depth, not just the top level).
        def walk_block_body(block_node, type_aliases, nested, &)
          body = block_node.body
          return if body.nil?

          children = body.is_a?(Prism::StatementsNode) ? body.body : [body]
          children.each { |child| visit_chain(child, type_aliases, nested, &) }
        end
        private_class_method :walk_block_body

        # `required(:key).filled(:string)` parses as a CallNode whose receiver is the `required(:key)`
        # call. Walk the chain inward looking for the type-bearing predicate at the head; the key sits on
        # the chain's tail. The `each(<Type>)` predicate yields a list-of-element type info (`{type: <T>,
        # list: true}`); other type-bearing predicates (`filled`/`value`/`maybe`) yield scalar info
        # (`{type: <T>, list: false}`).
        def visit_chain(node, type_aliases, nested, &block)
          return unless node.is_a?(Prism::CallNode)

          key, kind = extract_key_and_kind(node)
          return if key.nil?

          type_info = walk_predicate_chain(node, type_aliases, nested)
          block.call(kind, key, type_info)
        end
        private_class_method :visit_chain

        # `required(:key).filled(:string).value(...)...` — the OUTERMOST call's receiver chain ends in
        # the `required(:key)` / `optional(:key)` call. Recurse on `node.receiver` until we hit the
        # `required` / `optional` call, recording the key + kind.
        def extract_key_and_kind(node)
          current = node
          while current.is_a?(Prism::CallNode)
            if %i[required optional].include?(current.name)
              key = Rigor::Source::Literals.symbol(current.arguments&.arguments&.first)
              return [nil, nil] if key.nil?

              return [key, current.name]
            end
            current = current.receiver
          end
          [nil, nil]
        end
        private_class_method :extract_key_and_kind

        # Walks the call chain finding the first type-bearing predicate (`filled` / `value` / `maybe` /
        # `each`) and extracts its argument type. Returns a `{type:, list:}` tuple (`each` is the only
        # verb that produces a list) or nil when no recognisable type sits on the chain.
        #
        # `each do ... end` (a block instead of a type-symbol argument) is the ceiling's element-type
        # recursion (issue #137): the block is itself a nested schema declaration, walked with the SAME
        # algorithm as a top-level `Dry::Schema.X { ... }` body via {#each_block_type_info}. Already
        # `nested` (i.e. this chain is itself inside another `each do ... end`) declines a FURTHER each —
        # see {#collect_schema_shape}'s `nested:` doc for why the recursion caps at one level.
        def walk_predicate_chain(node, type_aliases, nested)
          current = node
          while current.is_a?(Prism::CallNode)
            if current.name == :each && current.block
              return nested ? nil : each_block_type_info(current.block, type_aliases)
            end

            if TYPE_BEARING_PREDICATES.include?(current.name)
              underlying = extract_type_from_predicate(current)
              return { type: underlying, list: current.name == :each } if underlying
            end
            current = current.receiver
          end
          nil
        end
        private_class_method :walk_predicate_chain

        # `required(:key).each do ... end` — recurses into the each-block using {#collect_schema_shape},
        # the identical row-collection algorithm a top-level schema body uses, so a nested `required` /
        # `optional` row gets the same predicate vocabulary, alias resolution, and untyped-row fallback as
        # the outer schema. Two spellings are recognised: the bare `each do required(:x)...; end` form, and
        # `each do schema do required(:x)...; end end` (dry-schema's alternate nested-hash spelling) via
        # {#nested_block_body}.
        #
        # A block that yields no row at all — a bare per-element predicate like `each { int? }`, which
        # this scanner does not model — declines (nil) rather than returning an empty nested shape: the key
        # falls through to {#unmodelled_keys} and renders `untyped`, the same "declined, not wrong" posture
        # every other unresolvable row already gets.
        def each_block_type_info(each_block, type_aliases)
          nested_shape = collect_schema_shape(nested_block_body(each_block), type_aliases, nested: true)
          return nil if nested_shape[:required].empty? && nested_shape[:optional].empty?

          { type: { nested: nested_shape }, list: true }
        end
        private_class_method :each_block_type_info

        # Unwraps the `each do schema do ... end end` spelling to the inner `schema` block; the bare
        # `each do required(...); ...; end` spelling passes the each-block through unchanged. Both declare
        # the same nested key set, just at a different literal nesting depth.
        def nested_block_body(each_block)
          body = each_block.body
          return each_block if body.nil?

          children = body.is_a?(Prism::StatementsNode) ? body.body : [body]
          return each_block unless children.size == 1

          single = children.first
          single.is_a?(Prism::CallNode) && single.name == :schema && single.block ? single.block : each_block
        end
        private_class_method :nested_block_body

        # Reads the first positional argument of a `filled(:string)` / `value(:integer)` /
        # `maybe(Types::Email)` call. Returns either the canonical-type-symbol's underlying class
        # ("String" / "Integer" / …), or the constant's qualified name for downstream type-alias
        # resolution. Returns nil for anything else.
        def extract_type_from_predicate(call_node)
          arg = call_node.arguments&.arguments&.first
          case arg
          when Prism::SymbolNode
            CANONICAL_TYPES[arg.unescaped.to_sym]
          when Prism::ConstantReadNode
            arg.name.to_s
          when Prism::ConstantPathNode
            constant_name_for(arg)
          end
        end
        private_class_method :extract_type_from_predicate

        # Keys the schema declares that this scanner saw but could not type — a predicate outside the
        # canonical vocabulary (`filled(:not_a_type)`), a nested `schema do … end` row, or a constant
        # alias no `:dry_type_aliases` fact resolved.
        #
        # They are recorded rather than forgotten so the schema's declared key set survives the scan even
        # where its types do not. {ResultShape} puts them back into the synthesized `to_h` shape as untyped
        # entries, which is what makes a hover read `{ email: String, address: Dynamic[top], ... }` instead
        # of a shape indistinguishable from one that never declared `address`. Consumers that only want
        # typed keys read `:required` / `:optional` and are unaffected.
        def unmodelled_keys(declared, required, optional)
          {
            required: (declared[:required] - required.keys).uniq.freeze,
            optional: (declared[:optional] - optional.keys).uniq.freeze
          }.freeze
        end
        private_class_method :unmodelled_keys

        # In-place: any value's `type:` slot in `bucket` that doesn't already match a canonical class
        # (e.g. `"Types::Email"`) gets resolved through the type_aliases fact. Unresolvable values drop
        # from the bucket (no fact contribution rather than misleading data). The `list:` slot rides along
        # unchanged.
        #
        # A nested-shape row (`type: {nested: {...}}`, from an `each do ... end` element-type recursion)
        # is already fully resolved by its own recursive {#collect_schema_shape} call — its `type:` slot is
        # a Hash, not a class-name String, and is skipped here rather than treated as an unresolvable alias.
        def remap_aliases!(bucket, type_aliases)
          canonical_set = CANONICAL_TYPES.values.to_set
          bucket.each_pair.to_a.each do |key, info|
            type_name = info.fetch(:type)
            next if type_name.is_a?(Hash) || canonical_set.include?(type_name)

            resolved = type_aliases[type_name]
            if resolved
              bucket[key] = info.merge(type: resolved)
            else
              bucket.delete(key)
            end
          end
        end
        private_class_method :remap_aliases!

        # Constant-path serialiser: `Dry::Schema` -> "Dry::Schema", bare `Foo` -> "Foo". Returns nil for
        # shapes Prism doesn't expose as ConstantRead/PathNode.
        def constant_name_for(node)
          return nil if node.nil?

          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
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
        end
        private_class_method :constant_name_for
      end
    end
  end
end
