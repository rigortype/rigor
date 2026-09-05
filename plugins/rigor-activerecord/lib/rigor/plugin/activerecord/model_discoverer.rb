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
      # Returns rows the {ModelIndex} consumes — exactly ONE per model, whatever the number of source
      # declarations: a reopened class contributes its DSL surface into the single row for that name
      # ({#merge_redeclarations}), because a reopen ADDS to a class rather than replacing it.
      #
      #   { class_name: "User", table_name_override: nil, sti_parent: nil, ... }
      #   { class_name: "Admin", table_name_override: nil, sti_parent: "User", ... }
      #
      # `class_name` (and `superclass_name`) is the constant path WITHOUT a leading `::` — `class ::User`
      # yields `"User"`, exactly as `class User` does, and `class ::User` nested inside `module Admin`
      # yields `"User"` rather than `"Admin::::User"`, because a rooted declaration names the top-level
      # constant regardless of its lexical nesting. Every downstream key — the {ModelIndex} entries, the
      # published `:model_index` fact, `Entry#class_name` — inherits this spelling, and every consumer
      # anchors with the plain constant rendering (#583: the rooted `"::User"` key used to make all three
      # Hash consumers miss such models silently).
      #
      # Limitations (intentional for v0.1.0 of the plugin):
      #
      # - `self.table_name = "..."` recognised only when the RHS is a String literal. Computed names
      #   (`self.table_name = "#{tenant}_users"`) are skipped.
      # - Modules (`class Admin::User < ApplicationRecord`) are recognised; the resulting class name is
      #   the lexical path (`Admin::User`). {ModelIndex.inflected_table_name} derives its TABLE name from
      #   only the demodulized last segment, `table_name_prefix` / `table_name_suffix` (#623).
      # - The STI fixpoint matches a superclass name against model class names by exact spelling; richer
      #   constant resolution (relative namespacing) is not modelled.
      # - An ENCLOSING namespace's (module OR class — Rails' own ancestor search does not care which)
      #   `table_name_prefix` / `table_name_suffix` is recognised as a String literal on `def self.NAME`,
      #   `class << self; def NAME`, a plain `self.NAME = "..."` assignment, or one of
      #   {ACCESSOR_DECLARATION_METHODS}'s `default:` (a `*_writer` macro does NOT establish the reader
      #   Rails' walk probes, so it is not recognised as declaring anything). Any other shape a reader
      #   establishment was observed for (a computed RHS, disagreeing reopenings, or a plain assignment with
      #   no tracked reader — an unrecognised reader spelling such as `define_singleton_method`,
      #   `module_function`, `extend self`, or a hand-rolled ivar reader all fall into this last case) is
      #   treated as DECLARED-BUT-UNFOLDABLE — and, per {ModelIndex.inflected_table_name_unreliable?}, does
      #   NOT fall back to a guessed value: the whole model's column/alias/association checks stand down
      #   instead, because a wrong guess can corroborate a real-but-unrelated table exactly as easily as it
      #   can miss.
      # - A model class NESTED INSIDE ANOTHER MODEL CLASS (`Post::Comment` where `Post < ApplicationRecord`
      #   — Rails splices the parent's own table name into the middle of the child's, a wholly different
      #   mechanism from prefix/suffix) is recognised and stands down the same way (#623 review). A model
      #   nested inside an ABSTRACT model reads its OWN demodulized name in real Rails (the splice only
      #   applies to a non-abstract parent) but this walker does not track `abstract_class?` and stands it
      #   down too — a coverage loss, never a false positive.
      # - A namespace's decorator declared OUTSIDE `model_search_paths` entirely is INVISIBLE, not stood
      #   down — this walker only reads files under the configured model roots, so a `table_name_prefix`
      #   anywhere else (a plain `def self.table_name_prefix` in `lib/blog.rb`, a
      #   `Rails::Engine.isolate_namespace` call in `lib/<engine>/engine.rb`, or any other path
      #   `model_search_paths` does not cover) resolves the bare demodulized guess uncorrected, exactly as
      #   if nothing had been declared. `Rigor::Plugin::IoBoundary`'s trust policy would permit reading
      #   further than `model_search_paths` for this plugin (its `allowed_read_roots` covers the project
      #   root), so an EXISTENCE-only scan of a wider file set is reachable in principle; it is not
      #   implemented because the right file set is a real design choice (the whole project root? `lib/`?
      #   each `engines/*/{app/models,lib}`?) and reading outside `model_search_paths` needs its own cache
      #   descriptor / `watch:` wiring to invalidate correctly — see the `producer :model_index` call site's
      #   `watch:` block, keyed on `model_search_paths` today.
      # - NOT modelled at all (pre-existing, unrelated to namespace prefixes): a model declaring
      #   `table_name_prefix` on ITSELF rather than an enclosing namespace, and a base class (e.g.
      #   `ApplicationRecord`) setting `self.table_name_prefix` for every model under it — both already
      #   guess wrong identically on unpatched code.
      class ModelDiscoverer
        # @param search_paths [Array<String>] absolute or project-relative paths.
        # @param base_classes [Array<String>] superclass names that identify a class as an AR model.
        # Declaration macros whose column's runtime value is a rich object, not the SQL scalar. Their column
        # must NOT be narrowed to the schema type (see {ModelIndex.build}'s type-override remap).
        TYPE_OVERRIDE_METHODS = %i[serialize mount_uploader mount_uploaders].freeze
        OUTSIDE_SEARCH_DIRECTORIES = %w[lib config engines].freeze

        def initialize(io_boundary:, search_paths:, base_classes:, project_root: ".")
          @io_boundary = io_boundary
          @search_paths = search_paths
          @project_root = project_root
          # De-rooted for the same reason superclass names are ({#visit_class}): the match is by exact
          # spelling, so a configured `model_base_classes: ["::ApplicationRecord"]` would otherwise never
          # match anything a declaration can render.
          @base_classes = base_classes.to_set { |name| strip_root(name.to_s) }
          # Global set of column names whose declared runtime type overrides the schema scalar
          # (`serialize` / `mount_uploader` / `attribute :x, CustomType`). Collected across every class AND
          # concern module walked — a serialize inside a concern's `included do … end` is invisible to the
          # per-model view (the discoverer doesn't follow `include`), so overrides are tracked globally by
          # column name and applied wherever that column appears. Over-suppresses a same-named scalar
          # column elsewhere (a precision cost, never a false positive).
          @type_override_columns = Set.new
          # `full namespace name => { prefix: decorator?, suffix: decorator? }` — what each walked module OR
          # class body declares about `table_name_prefix` / `table_name_suffix` (#623; keyed by full name
          # regardless of whether the source spelled the namespace `module` or `class` — Rails'
          # `module_parents` ancestor walk does not care either). A `decorator` is `{ literal: }` when
          # foldable to a String, `{ computed: true }` when the namespace declares the name in a shape this
          # walker cannot fold. A key absent from the inner Hash means the namespace says nothing about that
          # name — {#resolve_table_name_decorator} keeps walking outward past it, exactly like Rails' own
          # `respond_to?(:table_name_prefix)` ancestor search.
          @namespace_table_name_decorators = {}
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
          scan_outside_decorators
          superclass_map = build_superclass_map(candidates)
          # Every file is walked (and every module's `table_name_prefix` / `table_name_suffix` recorded)
          # before any row is resolved — a model's file may sort, and so be visited, before the file that
          # declares its enclosing module's decorator.
          attach_table_name_decorators(resolve_models(candidates), superclass_map: superclass_map)
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

          rows = candidates.filter_map do |candidate|
            name = candidate[:class_name]
            next unless model_names.key?(name)

            candidate.merge(sti_parent: sti_parent[name])
          end
          merge_redeclarations(rows)
        end

        # Collapses the rows that declare the SAME constant into one, so {ModelIndex.build} — which keys
        # its entries by `class_name` — receives at most one row per model.
        #
        # A model is routinely declared more than once: `app/models/user.rb` holds `class User <
        # ApplicationRecord` and a second file reopens it (`class ::User`, `class User`, or a full
        # `class User < ApplicationRecord` redeclaration) to add a method. Ruby's own semantics are
        # ADDITIVE — a reopen contributes what it spells and leaves the rest of the class alone — so the
        # rows are UNIONed here. Taking the last row instead dropped the real declaration's associations,
        # scopes, enums, validations, callbacks and `alias_attribute`s whenever the reopen sorted later in
        # the glob, and `where(<a declared alias>: …)` then surfaced a false `unknown-column` on correct
        # code; taking the first dropped whatever the reopen added. Neither order loses anything now.
        #
        # Merge is by field: the first non-nil `superclass_name` wins (a second declaration is the same
        # thing, or invalid Ruby); `self.table_name =` is an ASSIGNMENT, so the LATER declaration's
        # `table_name_override` wins as it does at load time, and when the two declarations disagree the
        # resolved name is marked computed so no value is pinned — the glob order is not the load order for
        # two full declarations, and a pinned wrong literal folds `Model.table_name == "…"` on correct code;
        # `table_name_computed` is otherwise an OR (any computed name in the class makes the resolved one
        # inexact); name-keyed rows (associations, enums, aliases) let the LAST declaration override an
        # earlier same-name row exactly as {ModelIndex.merge_named_rows} does across an STI chain, and the
        # plain lists union.
        def merge_redeclarations(rows)
          return rows if rows.length < 2

          rows.each_with_object({}) do |row, acc|
            name = row.fetch(:class_name)
            acc[name] = acc.key?(name) ? merged_row(acc[name], row) : row
          end.values
        end

        # `base` is the earlier declaration, `addition` the later one. See {#merge_redeclarations}.
        def merged_row(base, addition)
          base.merge(
            superclass_name: base[:superclass_name] || addition[:superclass_name],
            abstract_class: base[:abstract_class] || addition[:abstract_class],
            sti_parent: base[:sti_parent] || addition[:sti_parent],
            table_name_override: addition[:table_name_override] || base[:table_name_override],
            table_name_computed: base[:table_name_computed] || addition[:table_name_computed] ||
              conflicting_table_names?(base, addition),
            associations: dedup_named_rows(Array(base[:associations]) + Array(addition[:associations])),
            enums: (base[:enums] || {}).merge(addition[:enums] || {}),
            scopes: (Array(base[:scopes]) + Array(addition[:scopes])).uniq,
            validations: (Array(base[:validations]) + Array(addition[:validations])).uniq,
            callbacks: (Array(base[:callbacks]) + Array(addition[:callbacks])).uniq,
            aliases: (base[:aliases] || {}).merge(addition[:aliases] || {})
          )
        end

        # Two literal `self.table_name =` assignments that disagree: see {#merge_redeclarations}.
        def conflicting_table_names?(base, addition)
          a = base[:table_name_override]
          b = addition[:table_name_override]
          !a.nil? && !b.nil? && a != b
        end

        # Keeps the LAST row per `:name`, matching {ModelIndex.merge_named_rows}'s override rule.
        def dedup_named_rows(rows)
          rows.to_h { |row| [row[:name], row] }.values
        end

        # Resolves each model row's `table_name_prefix:` / `table_name_suffix:` / `table_name_nested_in_model:`
        # (#623, #671, #678, #679) against enclosing namespaces, model's own decorators, superclasses, and the
        # full discovered model set.
        #
        # Deliberately does NOT fold any of this into `table_name_computed` — that flag gates
        # `ModelIndex.table_name_exact?`, which only ever matters when a SOURCE-DECLARED literal
        # (`self.table_name = "…"`) exists, and a literal override bypasses Rails' whole
        # prefix/suffix/nesting computation at runtime. An unrelated namespace's unreadable decorator has no
        # bearing on whether that literal is what the app actually uses. What DOES depend on these three
        # fields is whether {ModelIndex.build} trusts the INFLECTED name enough to look up its columns —
        # see {ModelIndex.inflected_table_name_unreliable?}.
        def attach_table_name_decorators(rows, superclass_map: {})
          models_by_name = rows.to_h { |row| [row.fetch(:class_name), row] }
          rows.map do |row|
            class_name = row.fetch(:class_name)
            row.merge(
              table_name_prefix: resolve_table_name_decorator(class_name, :prefix, superclass_map: superclass_map),
              table_name_suffix: resolve_table_name_decorator(class_name, :suffix, superclass_map: superclass_map),
              table_name_nested_in_model: nested_in_model_class?(class_name, models_by_name)
            )
          end
        end

        # The decorator (`{ literal: }` / `{ computed: true }`) for `key`:
        # 1. First checks enclosing namespaces outward (mirroring Rails' `full_table_name_prefix`
        #    `module_parents` ancestor search).
        # 2. Checks the model's own class decorator.
        # 3. Walks the superclass hierarchy via `superclass_map` (e.g. `ApplicationRecord` or base classes).
        # Falls back to `{ literal: "" }` (AR::Base's own default) when nothing says anything about `key`.
        def resolve_table_name_decorator(class_name, key, superclass_map: {})
          namespace_ancestors(class_name).each do |namespace_name|
            decorator = @namespace_table_name_decorators[namespace_name]
            next unless decorator&.key?(key)

            return decorator[key]
          end

          decorator = @namespace_table_name_decorators[class_name]
          return decorator[key] if decorator&.key?(key)

          curr = superclass_map[class_name]
          visited = Set.new([class_name])
          while curr && !visited.include?(curr)
            visited << curr
            decorator = @namespace_table_name_decorators[curr]
            return decorator[key] if decorator&.key?(key)

            curr = superclass_map[curr]
          end

          { literal: "" }
        end

        def build_superclass_map(candidates)
          candidates_by_name = candidates.to_h { |c| [c[:class_name], c] }
          superclass_map = {}
          candidates.each do |c|
            name = c[:class_name]
            super_name = resolve_superclass_name(c, candidates_by_name)
            superclass_map[name] ||= super_name if super_name
          end
          superclass_map
        end

        def resolve_superclass_name(candidate, candidates_by_name)
          super_name = candidate[:superclass_name]
          return nil if super_name.nil?

          return super_name if candidates_by_name.key?(super_name) || @base_classes.include?(super_name)

          segments = candidate[:class_name].split("::")
          (segments.length - 1).downto(1).each do |n|
            prefix = segments.first(n).join("::")
            candidate_super = "#{prefix}::#{super_name}"
            return candidate_super if candidates_by_name.key?(candidate_super)
          end

          super_name
        end

        # `"Foo::Bar::Post"` → `["Foo::Bar", "Foo"]`, nearest first; a top-level `"Post"` → `[]`. Derived
        # purely from the (already de-rooted) class-name String, so it matches regardless of whether the
        # source nested the containing namespaces (`module Foo; module Bar` … / `class Foo; class Bar` …)
        # or wrote one compactly (`module Foo::Bar`).
        def namespace_ancestors(class_name)
          segments = class_name.split("::")
          (segments.length - 1).downto(1).map { |n| segments.first(n).join("::") }
        end

        # Whether `class_name`'s IMMEDIATE lexical parent is itself a non-abstract discovered model —
        # `Post::Comment` where `Post < ApplicationRecord` and `Post` is not abstract. Rails'
        # `compute_table_name` special-cases exactly this shape: it splices
        # `"#{parent.table_name.singularize}_"` into the middle of the name, entirely separately from the
        # `table_name_prefix` / `table_name_suffix` mechanism above (`ActiveRecord::ModelSchema::ClassMethods#compute_table_name`'s
        # `module_parent < Base && !module_parent.abstract_class?` arm).
        #
        # Abstract parents (`self.abstract_class = true` or `primary_abstract_class`) do NOT trigger this
        # containment rule in Rails — e.g. `Base::Comment` inflects to `"comments"` with normal live columns.
        def nested_in_model_class?(class_name, models_by_name)
          segments = class_name.split("::")
          return false if segments.length < 2

          parent_name = segments[0..-2].join("::")
          parent = models_by_name[parent_name]
          return false if parent.nil?

          parent[:abstract_class] != true
        end

        # Resolves a superclass NAME against the set of known model class names. Both sides come out of
        # {#declared_constant_name}, so neither carries a leading `::` and the match is by exact spelling.
        # Returns the matched model class name, or nil.
        def model_match(superclass_name, model_names)
          model_names.key?(superclass_name) ? superclass_name : nil
        end

        def read_safely(path)
          @io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        def ruby_files_under(roots)
          roots.flat_map do |root|
            absolute = File.expand_path(root)
            # ADR-45 WD1b (#613) — boundary-probed: a root that appears later invalidates the warm run.
            next [] unless @io_boundary.directory?(absolute)

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
          when Prism::CallNode
            handle_top_level_call(node, lexical_path)
          when Prism::DefNode
            handle_top_level_def(node)
          else
            node.rigor_each_child { |child| walk_for_classes(child, lexical_path, &) }
          end
        end

        def handle_top_level_call(node, lexical_path)
          if node.name == :isolate_namespace
            target = isolate_namespace_target(node, lexical_path.first)
            if target
              @namespace_table_name_decorators[target] ||= {}
              @namespace_table_name_decorators[target][:prefix] = { computed: true }
            end
          elsif node.receiver && %i[table_name_prefix= table_name_suffix=].include?(node.name)
            target = strip_root(constant_path_name(node.receiver))
            if target
              key = TABLE_NAME_DECORATOR_METHODS[node.name.to_s.delete_suffix("=").to_sym]
              @namespace_table_name_decorators[target] ||= {}
              @namespace_table_name_decorators[target][key] = literal_assignment_value(node)
            end
          end
        end

        def handle_top_level_def(node)
          return unless node.receiver

          target = strip_root(constant_path_name(node.receiver))
          return unless target

          key = TABLE_NAME_DECORATOR_METHODS[node.name]
          return unless key

          @namespace_table_name_decorators[target] ||= {}
          @namespace_table_name_decorators[target][key] = literal_def_value(node.body)
        end

        # Captures EVERY class declaration as a candidate — the `resolve_models` fixpoint decides
        # afterwards which ones are models. The DSL metadata is extracted eagerly; for a non-model class
        # it is simply discarded when the candidate is dropped.
        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = declared_constant_name(class_local_name, lexical_path)
          superclass = strip_root(constant_path_name(node.superclass)) if node.superclass

          collect_type_overrides(node.body)
          # Rails' `full_table_name_prefix` walks `module_parents.detect { respond_to?(:table_name_prefix) }`
          # — lexical nesting, which does not care whether the namespace container was written `module Blog`
          # or `class Blog`. A `class` used purely as a namespace holder (or a model class that happens to
          # ALSO declare a decorator for its own nested classes) must be scanned the same way a module is.
          record_table_name_decorators(full_name, node.body, is_class: true)

          yield({
            class_name: full_name,
            superclass_name: superclass,
            abstract_class: abstract_class?(node.body),
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
          walk_for_classes(node.body, [full_name], &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          # Concerns (`module DiffPositionableNote`) carry `serialize` / `mount_uploader` inside an
          # `included do … end` block; collect their overrides even though the module itself is not a model.
          collect_type_overrides(node.body)

          full_name = declared_constant_name(module_local_name, lexical_path)
          record_table_name_decorators(full_name, node.body, is_class: false)

          inner_path = [full_name]
          walk_for_classes(node.body, inner_path, &) if node.body
        end

        # The full constant name a `class` / `module` declaration defines, given the rendered local name
        # and the enclosing lexical path. A ROOTED local name (`class ::User`, `module ::Admin`) names the
        # top-level constant whatever the nesting, so the lexical path is dropped and the `::` with it;
        # otherwise the name is appended to the path (`class User` inside `module Admin` → `Admin::User`).
        def declared_constant_name(local_name, lexical_path)
          return strip_root(local_name) if local_name.start_with?("::")

          (lexical_path + [local_name]).join("::")
        end

        # `::User` → `User`; a name without the root marker is returned unchanged (nil stays nil).
        def strip_root(name)
          name&.delete_prefix("::")
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

        # Renders a constant-path node (`Admin::User`, `::ApplicationRecord`) as a String, keeping the
        # leading `::` of a rooted path — {#declared_constant_name} reads it as "reset the lexical path"
        # before the marker is dropped. Returns nil for shapes the discoverer chooses not to handle.
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

        # Whether a class declares itself abstract via `self.abstract_class = true` (or `abstract_class = true`)
        # or Rails 7+'s `primary_abstract_class` (#679). Abstract model classes are skipped by Rails' nested-model
        # containment prefixing rule in `compute_table_name`.
        def abstract_class?(body)
          return false if body.nil?

          body.rigor_each_child do |node|
            case node
            when Prism::CallNode
              if (node.name == :abstract_class=) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
                arg = node.arguments&.arguments&.first
                return true if arg.is_a?(Prism::TrueNode)
              elsif (node.name == :primary_abstract_class) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
                return true
              end
            when Prism::SingletonClassNode
              node.body&.rigor_each_child do |inner|
                next unless inner.is_a?(Prism::CallNode)

                if (inner.name == :abstract_class=) && (inner.receiver.nil? || inner.receiver.is_a?(Prism::SelfNode))
                  arg = inner.arguments&.arguments&.first
                  return true if arg.is_a?(Prism::TrueNode)
                elsif (inner.name == :primary_abstract_class) && (inner.receiver.nil? || inner.receiver.is_a?(Prism::SelfNode))
                  return true
                end
              end
            end
          end
          false
        end

        # `table_name_prefix` / `table_name_suffix`, keyed by the setter/reader name a namespace (module OR
        # class) body can declare either one under (#623). Rails' own table-name computation
        # (`ActiveRecord::ModelSchema::ClassMethods#full_table_name_prefix` / `#full_table_name_suffix`)
        # walks a namespaced model's enclosing namespaces outward via `module_parents` and asks each
        # `respond_to?(:table_name_prefix)` — a plain `Blog::Post` reads `posts` unless `Blog` answers that
        # question itself, whether `Blog` was declared `module Blog` or `class Blog`.
        TABLE_NAME_DECORATOR_METHODS = { table_name_prefix: :prefix, table_name_suffix: :suffix }.freeze
        private_constant :TABLE_NAME_DECORATOR_METHODS

        # The Rails/ActiveSupport macros that can declare a `table_name_prefix` / `table_name_suffix` READER
        # without a hand-written `def self.…`. Rails' walk tests `respond_to?(:table_name_prefix)` — the
        # READER — so this is every macro verified (against bundled `activesupport`) to define one:
        # `mattr_accessor` / `mattr_reader`, their `cattr_*` literal aliases, the `thread_mattr_*` /
        # `thread_cattr_*` thread-local family, and `class_attribute` (valid on a class namespace now that
        # {#visit_class} scans class bodies too — it is defined on `Class`, not `Module`). The `*_writer`
        # spellings (`mattr_writer`, `cattr_writer`, `thread_mattr_writer`, `thread_cattr_writer`) are
        # deliberately EXCLUDED: each defines only `self.#{sym}=` (verified against ActiveSupport's
        # `attribute_accessors.rb` / `attribute_accessors_per_thread.rb`), no reader, so a module declaring
        # only one of those is invisible to `full_table_name_prefix`'s ancestor search exactly as if it had
        # declared nothing.
        ACCESSOR_DECLARATION_METHODS = %i[
          mattr_accessor mattr_reader
          cattr_accessor cattr_reader
          thread_mattr_accessor thread_mattr_reader
          thread_cattr_accessor thread_cattr_reader
          class_attribute
        ].freeze
        private_constant :ACCESSOR_DECLARATION_METHODS

        # Scans a module OR class BODY for `table_name_prefix` / `table_name_suffix` declarations and
        # records what it finds into `@namespace_table_name_decorators`, merged with any earlier reopening
        # of the same namespace.
        def record_table_name_decorators(full_name, body, is_class: false)
          found = table_name_decorators(body, is_class: is_class)
          return if found.empty?

          existing = @namespace_table_name_decorators[full_name]
          @namespace_table_name_decorators[full_name] =
            existing.nil? ? found : merge_table_name_decorators(existing, found)
        end

        # Walks the namespace body's TOP-LEVEL statements only — a decorator declared inside a nested
        # `module`/`class` belongs to THAT namespace, not this one, and must not be attributed here.
        # Returns `Hash<:prefix|:suffix => { literal: } | { computed: true }>`, only for the names this body
        # actually mentions. A later statement overrides an earlier one within the SAME body — real Ruby
        # assignment order, not a guess: `mattr_accessor :table_name_prefix` (no `default:`, so `computed:
        # true`) followed two lines down by a real `self.table_name_prefix = "blog_"` folds to the literal.
        #
        # For a class (`is_class: true`), `ActiveRecord::Base` already defines reader accessors for
        # `table_name_prefix` and `table_name_suffix` (#671), so a plain assignment `self.NAME = "…"` folds
        # directly to the literal value without requiring an explicit reader declaration.
        #
        # For a module (`is_class: false`), plain assignment folds to the literal ONLY when a reader was
        # established earlier in the same body. An unrecognized or missing reader folds to `computed: true`.
        #
        # Four exotic reader spellings are recognized without assignment (#679):
        # 1. Singleton `attr_reader` (`class << self; attr_reader :table_name_prefix; end`) coupled with `@table_name_prefix = "…"`.
        # 2. `define_singleton_method(:table_name_prefix) { "…" }`.
        # 3. `module_function :table_name_prefix` or `module_function def table_name_prefix = "…"`.
        # 4. `extend self` with `def table_name_prefix = "…"`.
        def table_name_decorators(body, is_class: false)
          return {} if body.nil?

          decorators = {}
          readers = Set.new
          singleton_attr_readers = Set.new
          ivars = {}
          instance_methods = {}
          extend_self = false
          module_function_all = false

          body.rigor_each_child do |node|
            case node
            when Prism::DefNode
              if node.receiver.is_a?(Prism::SelfNode)
                key = TABLE_NAME_DECORATOR_METHODS[node.name]
                if key
                  readers << key
                  decorators[key] = literal_def_value(node.body)
                end
              elsif node.receiver.nil?
                key = TABLE_NAME_DECORATOR_METHODS[node.name]
                if key
                  val = literal_def_value(node.body)
                  instance_methods[key] = val
                  if extend_self || module_function_all
                    readers << key
                    decorators[key] = val
                  end
                end
              end
            when Prism::InstanceVariableWriteNode
              ivar_name = node.name.to_s.delete_prefix("@").to_sym
              key = TABLE_NAME_DECORATOR_METHODS[ivar_name]
              if key
                val = node.value.is_a?(Prism::StringNode) ? { literal: node.value.unescaped } : { computed: true }
                ivars[key] = val
                decorators[key] = val if singleton_attr_readers.include?(key)
              end
            when Prism::CallNode
              if node.receiver.is_a?(Prism::SelfNode) && node.name.to_s.end_with?("=")
                key = TABLE_NAME_DECORATOR_METHODS[node.name.to_s.delete_suffix("=").to_sym]
                if key
                  decorators[key] = readers.include?(key) || is_class ? literal_assignment_value(node) : { computed: true }
                end
              elsif (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
                    ACCESSOR_DECLARATION_METHODS.include?(node.name)
                found = mattr_decorator_values(node)
                readers.merge(found.keys)
                decorators.merge!(found)
              elsif (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
                    node.name == :define_singleton_method
                arg0 = node.arguments&.arguments&.first
                name = Rigor::Source::Literals.symbol_name(arg0) || (arg0.is_a?(Prism::StringNode) ? arg0.unescaped : nil)
                key = TABLE_NAME_DECORATOR_METHODS[name.to_sym] if name
                if key
                  readers << key
                  decorators[key] = node.block.is_a?(Prism::BlockNode) ? literal_def_value(node.block.body) : { computed: true }
                end
              elsif (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) && node.name == :extend
                arg = node.arguments&.arguments&.first
                if arg.is_a?(Prism::SelfNode)
                  extend_self = true
                  instance_methods.each do |k, v|
                    readers << k
                    decorators[k] = v
                  end
                end
              elsif (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) && node.name == :module_function
                args = node.arguments&.arguments || []
                if args.empty?
                  module_function_all = true
                  instance_methods.each do |k, v|
                    readers << k
                    decorators[k] = v
                  end
                else
                  args.each do |arg|
                    if arg.is_a?(Prism::DefNode)
                      k = TABLE_NAME_DECORATOR_METHODS[arg.name]
                      if k
                        readers << k
                        decorators[k] = literal_def_value(arg.body)
                      end
                    else
                      sym = Rigor::Source::Literals.symbol_name(arg) || (arg.is_a?(Prism::StringNode) ? arg.unescaped : nil)
                      k = TABLE_NAME_DECORATOR_METHODS[sym.to_sym] if sym
                      if k
                        readers << k
                        decorators[k] = instance_methods[k] || { computed: true }
                      end
                    end
                  end
                end
              end
            when Prism::SingletonClassNode
              found_decorators, found_readers, found_attr_readers = singleton_class_decorator_values(node, ivars)
              readers.merge(found_readers)
              singleton_attr_readers.merge(found_attr_readers)
              decorators.merge!(found_decorators)
            end
          end
          decorators
        end

        # `class << self; def table_name_prefix = "blog_"; end; end` or `class << self; attr_reader :table_name_prefix; end`
        # (#623, #679).
        def singleton_class_decorator_values(node, ivars = {})
          return [{}, Set.new, Set.new] unless node.body

          decorators = {}
          readers = Set.new
          attr_readers = Set.new

          node.body.rigor_each_child do |inner|
            case inner
            when Prism::DefNode
              next unless inner.receiver.nil?

              key = TABLE_NAME_DECORATOR_METHODS[inner.name]
              if key
                readers << key
                decorators[key] = literal_def_value(inner.body)
              end
            when Prism::CallNode
              next unless inner.receiver.nil? && inner.name == :attr_reader

              args = inner.arguments&.arguments || []
              args.each do |arg|
                name = Rigor::Source::Literals.symbol_name(arg) || (arg.is_a?(Prism::StringNode) ? arg.unescaped : nil)
                key = TABLE_NAME_DECORATOR_METHODS[name.to_sym] if name
                next unless key

                readers << key
                attr_readers << key
                decorators[key] = ivars[key] || { computed: true }
              end
            when Prism::InstanceVariableWriteNode
              ivar_name = inner.name.to_s.delete_prefix("@").to_sym
              key = TABLE_NAME_DECORATOR_METHODS[ivar_name]
              if key
                val = inner.value.is_a?(Prism::StringNode) ? { literal: inner.value.unescaped } : { computed: true }
                ivars[key] = val
                decorators[key] = val if attr_readers.include?(key)
              end
            end
          end

          [decorators, readers, attr_readers]
        end

        # `def self.table_name_prefix = "blog_"` and the equivalent regular-method spelling both parse to a
        # `DefNode` whose `body` is a one-statement `StatementsNode` — fold when that statement is a String
        # literal. An empty body (`def self.table_name_prefix; end`), a multi-statement body, or a
        # non-literal single statement (string interpolation, a method call) all decline: the module DOES
        # declare the name, this walker just cannot read off its value.
        def literal_def_value(def_body)
          return { computed: true } if def_body.nil?

          statements = def_body.body
          return { computed: true } unless statements.size == 1 && statements.first.is_a?(Prism::StringNode)

          { literal: statements.first.unescaped }
        end

        # `self.table_name_prefix = "blog_"` — the plain-assignment spelling (with or without a preceding
        # `mattr_accessor` establishing the writer). Declines to `computed: true` for a non-literal RHS.
        def literal_assignment_value(node)
          arg = node.arguments&.arguments&.first
          return { literal: arg.unescaped } if arg.is_a?(Prism::StringNode)

          { computed: true }
        end

        # `mattr_accessor :table_name_prefix, :table_name_suffix, default: "blog_"` — every
        # {ACCESSOR_DECLARATION_METHODS} macro shares this same call shape: one `default:` across every
        # Symbol name the call declares. Returns a Hash keyed by the `:prefix` / `:suffix` names this call
        # actually declares; a name with no literal `default:` folds to `{ computed: true }` rather than
        # assuming the runtime default of `nil` (a LATER plain assignment in the same body can still upgrade
        # it — see {#table_name_decorators}).
        def mattr_decorator_values(node)
          args = node.arguments&.arguments
          return {} if args.nil?

          keys = args.filter_map do |arg|
            name = Rigor::Source::Literals.symbol_name(arg)
            TABLE_NAME_DECORATOR_METHODS[name.to_sym] if name
          end
          return {} if keys.empty?

          value = mattr_default_value(args)
          keys.to_h { |key| [key, value] }
        end

        def mattr_default_value(args)
          hash_arg = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
          return { computed: true } if hash_arg.nil?

          pair = hash_arg.elements.find do |el|
            el.is_a?(Prism::AssocNode) && Rigor::Source::Literals.symbol_named?(el.key, "default")
          end
          return { computed: true } if pair.nil? || !pair.value.is_a?(Prism::StringNode)

          { literal: pair.value.unescaped }
        end

        # Merges the decorator findings of two reopenings of the SAME module. A key present on only one
        # side wins outright; a key BOTH sides declare wins only when they agree (the same literal) — a
        # cross-file "later wins" order is not derivable (glob order isn't load order, the same reasoning
        # {#conflicting_table_names?} applies to `self.table_name =`), so a disagreement folds to
        # `computed: true` rather than picking one arbitrarily.
        def merge_table_name_decorators(base, addition)
          (base.keys | addition.keys).to_h do |key|
            a = base[key]
            b = addition[key]
            value =
              if a.nil? then b
              elsif b.nil? then a
              elsif a == b then a
              else { computed: true }
              end
            [key, value]
          end
        end

        # Scans ruby files under project root outside model search paths for table_name_prefix /
        # table_name_suffix / isolate_namespace (#678).
        def scan_outside_decorators
          outside_ruby_files.each do |path|
            contents = read_safely(path)
            next if contents.nil?
            next unless outside_decorator_candidate?(contents)

            parsed = Prism.parse(contents)
            next if parsed.failure?

            walk_for_outside_decorators(parsed.value, [])
          end
        end

        def outside_ruby_files
          model_files = ruby_files_under(@search_paths).to_set
          root = File.expand_path(@project_root)
          return [] unless @io_boundary.directory?(root)

          outside_roots = OUTSIDE_SEARCH_DIRECTORIES.map { |dir| File.join(root, dir) }
          ruby_files_under(outside_roots).reject { |path| model_files.include?(path) }
        end

        def outside_decorator_candidate?(contents)
          contents.include?("table_name_prefix") ||
            contents.include?("table_name_suffix") ||
            contents.include?("isolate_namespace")
        end

        def walk_for_outside_decorators(node, lexical_path)
          return if node.nil?

          case node
          when Prism::ClassNode
            class_local_name = constant_path_name(node.constant_path)
            if class_local_name
              full_name = declared_constant_name(class_local_name, lexical_path)
              record_outside_decorators(full_name, node.body, [full_name, *lexical_path], is_class: true)
              node.body&.rigor_each_child { |child| walk_for_outside_decorators(child, [full_name, *lexical_path]) }
            end
          when Prism::ModuleNode
            module_local_name = constant_path_name(node.constant_path)
            if module_local_name
              full_name = declared_constant_name(module_local_name, lexical_path)
              record_outside_decorators(full_name, node.body, [full_name, *lexical_path], is_class: false)
              node.body&.rigor_each_child { |child| walk_for_outside_decorators(child, [full_name, *lexical_path]) }
            end
          when Prism::CallNode
            handle_outside_call(node, lexical_path)
          when Prism::DefNode
            handle_outside_def(node)
          else
            node.rigor_each_child { |child| walk_for_outside_decorators(child, lexical_path) }
          end
        end

        def record_outside_decorators(full_name, body, lexical_path, is_class: false)
          return if body.nil?

          found = table_name_decorators(body, is_class: is_class)
          if found.any?
            @namespace_table_name_decorators[full_name] ||= {}
            found.each_key do |key|
              @namespace_table_name_decorators[full_name][key] = { computed: true }
            end
          end

          body.rigor_each_child do |child|
            if child.is_a?(Prism::CallNode) && child.name == :isolate_namespace
              target = isolate_namespace_target(child, lexical_path.first)
              if target
                @namespace_table_name_decorators[target] ||= {}
                @namespace_table_name_decorators[target][:prefix] = { computed: true }
              end
            end
          end
        end

        def handle_outside_call(node, lexical_path)
          if node.name == :isolate_namespace
            target = isolate_namespace_target(node, lexical_path.first)
            if target
              @namespace_table_name_decorators[target] ||= {}
              @namespace_table_name_decorators[target][:prefix] = { computed: true }
            end
          elsif node.receiver && %i[table_name_prefix= table_name_suffix=].include?(node.name)
            target = strip_root(constant_path_name(node.receiver))
            if target
              key = TABLE_NAME_DECORATOR_METHODS[node.name.to_s.delete_suffix("=").to_sym]
              if key
                @namespace_table_name_decorators[target] ||= {}
                @namespace_table_name_decorators[target][key] = { computed: true }
              end
            end
          end
        end

        def handle_outside_def(node)
          return unless node.receiver

          target = strip_root(constant_path_name(node.receiver))
          return unless target

          key = TABLE_NAME_DECORATOR_METHODS[node.name]
          return unless key

          @namespace_table_name_decorators[target] ||= {}
          @namespace_table_name_decorators[target][key] = { computed: true }
        end

        def isolate_namespace_target(node, lexical_name)
          arg = node.arguments&.arguments&.first
          if arg
            name = constant_path_name(arg)
            strip_root(name) if name
          elsif lexical_name
            segments = lexical_name.to_s.split("::")
            segments.length > 1 ? segments[0..-2].join("::") : segments.first
          end
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
