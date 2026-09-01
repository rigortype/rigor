# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"
require "rigor/source/literals"

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Walks the configured model search paths via the plugin's `IoBoundary`, parses each `.rb` file with
      # Prism, and collects class declarations that resolve to ActiveRecord models.
      #
      # Discovery is a two-step pass. First every class declaration is captured as a *candidate* (its
      # name, its superclass name, and its DSL metadata). Then a fixpoint marks a candidate as a model
      # when its superclass is a configured base class OR (transitively) the class name of another model
      # — this is what makes single-table-inheritance subclasses (`class Admin < User`) discoverable.
      # Each STI child carries an `sti_parent:` pointer the {ModelIndex} uses to inherit the root model's
      # table and DSL surface.
      #
      # Returns rows the {ModelIndex} consumes:
      #
      #   { class_name: "User", table_name_override: nil, sti_parent: nil, ... }
      #   { class_name: "Admin", table_name_override: nil, sti_parent: "User", ... }
      #
      # Limitations (intentional for v0.1.0 of the plugin):
      #
      # - `self.table_name = "..."` recognised only when the RHS is a String literal. Computed names
      #   (`self.table_name = "#{tenant}_users"`) are skipped.
      # - Modules (`class Admin::User < ApplicationRecord`) are recognised; the resulting class name is
      #   the lexical path (`Admin::User`).
      # - The STI fixpoint matches a superclass name against model class names tolerating a leading `::`;
      #   richer constant resolution (relative namespacing) is not modelled.
      class ModelDiscoverer
        # @param io_boundary [Rigor::Plugin::IoBoundary]
        # @param search_paths [Array<String>] absolute or project-relative paths.
        # @param base_classes [Array<String>] superclass names that identify a class as an AR model.
        # Declaration macros whose column's runtime value is a rich object, not the SQL scalar. Their column
        # must NOT be narrowed to the schema type (see {ModelIndex.build}'s type-override remap).
        TYPE_OVERRIDE_METHODS = %i[serialize mount_uploader mount_uploaders].freeze

        def initialize(io_boundary:, search_paths:, base_classes:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          @base_classes = base_classes.to_set
          # Global set of column names whose declared runtime type overrides the schema scalar
          # (`serialize` / `mount_uploader` / `attribute :x, CustomType`). Collected across every class AND
          # concern module walked — a serialize inside a concern's `included do … end` is invisible to the
          # per-model view (the discoverer doesn't follow `include`), so overrides are tracked globally by
          # column name and applied wherever that column appears. Over-suppresses a same-named scalar
          # column elsewhere (a precision cost, never a false positive).
          @type_override_columns = Set.new
        end

        attr_reader :type_override_columns

        # @return [Array<Hash>] rows of { class_name:, table_name_override:, sti_parent:, ... }
        def discover
          candidates = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_classes(tree, []) { |candidate| candidates << candidate }
          end
          resolve_models(candidates)
        end

        private

        # Fixpoint over the captured class candidates: a candidate is a model when its superclass is a
        # configured base class, or — transitively — the class name of an already-known model. The
        # second arm is what discovers STI subclasses; the matched parent name is stamped onto the row as
        # `sti_parent:` so the {ModelIndex} can inherit the root model's table and association surface.
        #
        # Non-model classes (POROs, service objects that happen to live under `app/models/`) never enter
        # `model_names` and are dropped.
        def resolve_models(candidates)
          model_names = {}
          sti_parent = {}

          loop do
            added = false
            candidates.each do |candidate|
              name = candidate[:class_name]
              next if model_names.key?(name)

              superclass = candidate[:superclass_name]
              next if superclass.nil?

              if @base_classes.include?(superclass)
                model_names[name] = true
                added = true
              elsif (parent = model_match(superclass, model_names))
                model_names[name] = true
                sti_parent[name] = parent
                added = true
              end
            end
            break unless added
          end

          candidates.filter_map do |candidate|
            name = candidate[:class_name]
            next unless model_names.key?(name)

            candidate.merge(sti_parent: sti_parent[name])
          end
        end

        # Resolves a superclass NAME against the set of known model class names, tolerating a leading
        # `::`. Returns the matched model class name, or nil.
        def model_match(superclass_name, model_names)
          return superclass_name if model_names.key?(superclass_name)

          stripped = superclass_name.sub(/\A::/, "")
          model_names.key?(stripped) ? stripped : nil
        end

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
            node.rigor_each_child { |child| walk_for_classes(child, lexical_path, &) }
          end
        end

        # Captures EVERY class declaration as a candidate — the `resolve_models` fixpoint decides
        # afterwards which ones are models. The DSL metadata is extracted eagerly; for a non-model class
        # it is simply discarded when the candidate is dropped.
        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = (lexical_path + [class_local_name]).join("::")
          superclass = constant_path_name(node.superclass) if node.superclass

          collect_type_overrides(node.body)

          yield({
            class_name: full_name,
            superclass_name: superclass,
            table_name_override: lookup_table_name_override(node.body),
            table_name_computed: table_name_computed?(node.body),
            associations: lookup_associations(node.body),
            enums: lookup_enums(node.body),
            scopes: lookup_scopes(node.body),
            validations: lookup_validations(node.body),
            callbacks: lookup_callbacks(node.body),
            aliases: lookup_aliases(node.body)
          })

          # Recurse into the body in case nested classes exist.
          inner_path = lexical_path + [class_local_name]
          walk_for_classes(node.body, inner_path, &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          # Concerns (`module DiffPositionableNote`) carry `serialize` / `mount_uploader` inside an
          # `included do … end` block; collect their overrides even though the module itself is not a model.
          collect_type_overrides(node.body)

          inner_path = lexical_path + [module_local_name]
          walk_for_classes(node.body, inner_path, &) if node.body
        end

        # Records the column name of every `serialize :col` / `mount_uploader(s) :col` / `attribute :col,
        # CustomType` in `body` (descending into `with_options` and concern `included do` blocks) into the
        # global {#type_override_columns} set. `attribute :col, :symbol_type` (a built-in scalar type) is
        # NOT an override — only a custom type CONSTANT is.
        def collect_type_overrides(body)
          type_override_declaration_calls(body).each do |node|
            next if node.receiver

            column = Rigor::Source::Literals.symbol_name(node.arguments&.arguments&.first)
            next if column.nil?

            if TYPE_OVERRIDE_METHODS.include?(node.name)
              @type_override_columns << column
            elsif node.name == :attribute && custom_type_attribute?(node)
              @type_override_columns << column
            end
          end
        end

        # `declaration_calls` variant that also descends into a concern's `included do … end` block (the
        # ActiveSupport::Concern idiom where models' shared `serialize` declarations live).
        def type_override_declaration_calls(body)
          return [] if body.nil?

          body.compact_child_nodes.flat_map do |node|
            next [] unless node.is_a?(Prism::CallNode)

            if %i[with_options included].include?(node.name) && node.block.is_a?(Prism::BlockNode)
              type_override_declaration_calls(node.block.body)
            else
              [node]
            end
          end
        end

        # True when an `attribute :col, <type>` call's type argument is a custom type CLASS (a constant),
        # whose runtime value is a rich object — not a built-in `:symbol` type, which stays a scalar.
        def custom_type_attribute?(node)
          type_arg = node.arguments&.arguments&.[](1)
          type_arg.is_a?(Prism::ConstantReadNode) || type_arg.is_a?(Prism::ConstantPathNode)
        end

        # Renders a constant-path node (`Admin::User`, `::ApplicationRecord`) as a String. Returns nil for
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

        # Looks for `self.table_name = "..."` at the top level of the class body. Returns the literal
        # String when found, nil otherwise.
        def lookup_table_name_override(body)
          return nil if body.nil?

          body.rigor_each_child do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :table_name=
            next unless node.receiver.is_a?(Prism::SelfNode)

            arg = node.arguments&.arguments&.first
            return arg.unescaped if arg.is_a?(Prism::StringNode)
          end
          nil
        end

        # Whether the class computes its own table name in a way this walker cannot read off the source:
        # `def self.table_name`, a `table_name` def inside `class << self`, or `self.table_name =` with a
        # non-literal RHS (`"#{tenant}_users"`).
        #
        # The resolved name is unaffected — it still falls back to the inflection, and a wrong inflection
        # already degrades harmlessly (no matching table → no columns → the analyzer stays silent). What
        # this flag protects is the {ModelIndex::Entry#table_name_exact?} claim, which licenses PINNING the
        # name to a value. Without it, a computed override on a class whose inflected name happens to match
        # some table in the schema would read as corroborated, and `Model.table_name == "..."` would then
        # fold against a name the application does not use.
        def table_name_computed?(body)
          return false if body.nil?

          body.rigor_each_child do |node|
            return true if singleton_table_name_def?(node)
            return true if singleton_class_defines_table_name?(node)
            return true if non_literal_table_name_assignment?(node)
          end
          false
        end

        # `def self.table_name` — a DefNode with an explicit `self` receiver.
        def singleton_table_name_def?(node)
          node.is_a?(Prism::DefNode) && node.name == :table_name && node.receiver.is_a?(Prism::SelfNode)
        end

        # `class << self; def table_name; …; end; end` — the other spelling of the same override.
        def singleton_class_defines_table_name?(node)
          return false unless node.is_a?(Prism::SingletonClassNode)
          return false unless node.body

          node.body.rigor_each_child do |inner|
            return true if inner.is_a?(Prism::DefNode) && inner.name == :table_name && inner.receiver.nil?
          end
          false
        end

        # `self.table_name = <anything but a String literal>`. The literal form is the one
        # {#lookup_table_name_override} reads; everything else is a name only the running app knows.
        def non_literal_table_name_assignment?(node)
          return false unless node.is_a?(Prism::CallNode) && node.name == :table_name=
          return false unless node.receiver.is_a?(Prism::SelfNode)

          !node.arguments&.arguments&.first.is_a?(Prism::StringNode)
        end

        # Recognised single-instance and collection association DSL methods. The kind drives the eventual
        # return-type contribution: singular associations narrow to `Nominal[Target] | nil`, plural ones
        # narrow to `ActiveRecord::Relation[Target]`.
        #
        # `composed_of` value-object aggregations and `delegated_type` roles are folded in here too — both
        # accept the association name as a `where` / `find_by` query key, so omitting them turns every
        # such query into a false `unknown-column`. `composed_of` resolves to its value class (a real
        # target); `delegated_type` is polymorphic (no single target).
        ASSOCIATION_METHODS = {
          belongs_to: :singular,
          has_one: :singular,
          has_many: :collection,
          has_and_belongs_to_many: :collection,
          composed_of: :singular,
          delegated_type: :singular
        }.freeze
        private_constant :ASSOCIATION_METHODS

        # Association DSL methods that are ALWAYS polymorphic — the accessor has no single static target
        # class. `belongs_to` / `has_one` become polymorphic only with an explicit `polymorphic: true`
        # option.
        POLYMORPHIC_BY_DEFAULT = %i[delegated_type].freeze
        private_constant :POLYMORPHIC_BY_DEFAULT

        # Class-body declaration calls — the top-level `CallNode`s PLUS those nested inside a
        # `with_options(...) do … end` block. `with_options` is Rails' idiom for sharing options across a
        # group of `belongs_to` / `validates` / etc. declarations; without descending into it every
        # association / enum / validation declared inside is invisible to the discoverer, turning
        # `where(<assoc>: ...)` into a false `unknown-column`. Nested `with_options` blocks recurse.
        #
        # The options the `with_options` call itself carries (e.g. `with_options class_name: 'Account'`)
        # are NOT merged into the nested calls — discovering the declaration name is what clears the
        # false positive; the merged-option target precision is a separate refinement.
        def declaration_calls(body)
          return [] if body.nil?

          body.compact_child_nodes.flat_map do |node|
            next [] unless node.is_a?(Prism::CallNode)

            if node.name == :with_options && node.block.is_a?(Prism::BlockNode)
              declaration_calls(node.block.body)
            else
              [node]
            end
          end
        end

        # Walks the class body for association DSL calls and returns a list of rows shaped:
        #
        #     { name: "user", kind: :singular, target: "User" }
        #
        # The `target` is resolved from an explicit `class_name: "Foo"` option when supplied, otherwise
        # inferred from the association name via {Inflector.classify}. Calls whose first arg is not a
        # Symbol literal (or whose `class_name:` is a non-literal expression) decline rather than guess.
        def lookup_associations(body)
          return [] if body.nil?

          rows = []
          declaration_calls(body).each do |node|
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

          name = Rigor::Source::Literals.symbol_name(args.first)
          return nil if name.nil?

          polymorphic = POLYMORPHIC_BY_DEFAULT.include?(node.name) ||
                        association_option(args, "polymorphic") == true

          # A polymorphic association has no single static target class — `target` is nil and the flow
          # contribution declines to narrow rather than inventing a wrong `Nominal[<classified-name>]`.
          if polymorphic
            target = nil
          else
            target = explicit_class_name(args) || Rigor::Plugin::Inflector.classify(name)
            return nil if target.nil? || target.empty?
          end

          { name: name, kind: kind, target: target, polymorphic: polymorphic,
            nullable: association_nullable?(node.name, args) }
        end

        # Whether a `:singular` association's accessor can return `nil`. `has_one` genuinely can (no
        # associated record → `nil`). `belongs_to` is **required (non-`nil`) by default since Rails 5**
        # (`belongs_to_required_by_default`); it becomes nullable only when the call passes
        # `optional: true` or `required: false`. `composed_of` is non-nullable unless `allow_nil: true`.
        # `delegated_type` roles are required. A non-literal option value declines to the default rather
        # than guessing.
        def association_nullable?(method_name, args)
          case method_name
          when :has_one
            true
          when :belongs_to
            association_option(args, "optional") == true ||
              association_option(args, "required") == false
          when :composed_of
            association_option(args, "allow_nil") == true
          else
            false
          end
        end

        # Reads a literal boolean association option (`optional:` / `required:`). Returns `true` / `false`
        # for a literal, or `nil` when the key is absent or its value is non-literal.
        def association_option(args, key)
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |pair|
              next unless pair.is_a?(Prism::AssocNode) && Source::Literals.symbol_named?(pair.key, key)

              return true if pair.value.is_a?(Prism::TrueNode)
              return false if pair.value.is_a?(Prism::FalseNode)
            end
          end
          nil
        end

        def explicit_class_name(args)
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |pair|
              next unless pair.is_a?(Prism::AssocNode) && Source::Literals.symbol_named?(pair.key, "class_name")
              next unless pair.value.is_a?(Prism::StringNode)

              return pair.value.unescaped
            end
          end
          nil
        end

        # `enum status: { active: 0, archived: 1 }` (Rails ≤6) and `enum :status, [:active, :archived]`
        # (Rails 7+). Returns `Hash<column_name => Array<Symbol>>`. Non-literal forms decline rather than
        # guess.
        def lookup_enums(body)
          return {} if body.nil?

          enums = {}
          declaration_calls(body).each do |node|
            next unless node.name == :enum
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

        # `scope :active, -> { ... }`. Records the scope name only (the body is intentionally NOT
        # introspected — the caller contributes `ActiveRecord::Relation[Model]` based on the name alone
        # via `class_scope_return_type`).
        def lookup_scopes(body)
          return [] if body.nil?

          scopes = []
          declaration_calls(body).each do |node|
            next unless node.name == :scope
            next if node.receiver

            args = node.arguments&.arguments
            next if args.nil? || args.empty?

            name_node = args.first
            next unless name_node.is_a?(Prism::SymbolNode)

            scopes << name_node.unescaped
          end
          scopes.freeze
        end

        # `validates :name, presence: true, length: { maximum: 100 }`. Records the attribute name (the
        # validator option set is ignored — the value here is the diagnostic `validates :unknown_attr`
        # surfacing when the attribute isn't a column on the table).
        def lookup_validations(body)
          return [] if body.nil?

          attrs = []
          declaration_calls(body).each do |node|
            next unless %i[validates validates_presence_of validates_length_of
                           validates_format_of validates_uniqueness_of].include?(node.name)
            next if node.receiver

            attrs.concat(symbol_args(node))
          end
          attrs.uniq.freeze
        end

        # `before_save :foo`, `after_create :bar`, etc. Records the referenced method name (a Symbol
        # literal). The diagnostic value is "did you forget to `def` this?". Block callbacks
        # (`before_save { ... }`) decline.
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
          declaration_calls(body).each do |node|
            next unless CALLBACK_METHODS.include?(node.name)
            next if node.receiver

            symbol_args(node).each do |name|
              targets << { name: name, callback: node.name.to_s }
            end
          end
          targets.freeze
        end

        # `alias_attribute :new_name, :old_name`. Records the mapping so the analyzer accepts the alias
        # as a query key — without it every `where(<alias>: ...)` / `find_by(<alias>: ...)` call surfaces
        # as a false `unknown-column`. Returns `Hash<alias => target>`; non-Symbol-literal forms decline
        # rather than guess.
        def lookup_aliases(body)
          return {} if body.nil?

          aliases = {}
          declaration_calls(body).each do |node|
            next unless node.name == :alias_attribute
            next if node.receiver

            args = node.arguments&.arguments
            next if args.nil? || args.size < 2

            new_name = args[0]
            old_name = args[1]
            next unless new_name.is_a?(Prism::SymbolNode) && old_name.is_a?(Prism::SymbolNode)

            aliases[new_name.unescaped] = old_name.unescaped
          end
          aliases.freeze
        end

        # Collects every Symbol-literal positional argument from a CallNode. Used by both
        # `lookup_validations` and `lookup_callbacks` to extract the attribute / method name list.
        def symbol_args(node)
          args = node.arguments&.arguments
          return [] if args.nil?

          args.filter_map { |arg| arg.unescaped if arg.is_a?(Prism::SymbolNode) }
        end
      end
    end
  end
end
