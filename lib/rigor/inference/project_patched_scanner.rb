# frozen_string_literal: true

require "prism"

require_relative "project_patched_methods"
require_relative "../analysis/dependency_source_inference/return_type_heuristic"
require_relative "../source/alias_names"
require_relative "../source/constant_path"
require_relative "../source/node_children"

module Rigor
  module Inference
    # ADR-17 slice 2 — pre-pass scanner. Walks every file the user listed under `pre_eval:` and
    # harvests every `def` / `def self.` declaration inside a class / module body into a
    # {ProjectPatchedMethods} registry the dispatcher consults below the plugin tier, together with every
    # `alias new old` / `alias_method :new, :old` there (issue #1702, read through {Source::AliasNames}).
    #
    # The walker is intentionally a strict subset of {Rigor::Inference::ScopeIndexer}'s machinery: it
    # only needs `class C; def m; end; end` shape recognition, not full inference. Parse errors degrade
    # to a fail-soft `:warning` `pre-eval.parse-error` diagnostic accumulated alongside the registry;
    # per ADR-17 § "Failure modes" a parse failure in a pre-eval file MUST NOT abort the rest of the run.
    module ProjectPatchedScanner
      # Frozen scan outcome carrying the populated registry and the per-file warnings the runner emits
      # at run start.
      class Result < Data.define(:registry, :diagnostics)
        def initialize(registry:, diagnostics: [])
          super(
            registry: registry,
            diagnostics: diagnostics.freeze
          )
        end
      end

      # An alias the walk met, before {resolve_aliases} knows whether its old name is one the patch files define.
      PendingAlias = Data.define(:class_name, :new_name, :old_name, :kind, :source_path, :source_line)
      private_constant :PendingAlias

      module_function

      # @param paths — absolute paths to the pre-eval files. The runner has already
      #   validated that each path exists (slice-1 `pre-eval.file-not-found` `:error` covers missing
      #   entries); the scanner does NOT re-check existence.
      # @param buffer — editor-mode buffer binding. When set, the
      #   scanner reads the buffer's physical bytes if a pre-eval entry matches the logical path, so
      #   users editing a monkey-patch file see the in-flight version in their analysis.
      # @return the populated registry plus any per-file warnings.
      def scan(paths, buffer: nil)
        collected = []
        diagnostics = []
        census = Set.new
        paths.each { |path| scan_file(path, collected, diagnostics, buffer, census) }
        entries = resolve_aliases(collected)
        diagnostics.concat(duplicate_declaration_diagnostics(entries))
        Result.new(
          registry: ProjectPatchedMethods.new(entries: entries, write_census: census.freeze),
          diagnostics: diagnostics
        )
      end

      # ADR-17 § "Failure modes" — when two pre-eval entries declare the same `(class_name, method_name,
      # kind)` triple, emit one `:info` `pre-eval.duplicate-declaration` diagnostic per collision. The
      # registry's first-write-wins behaviour is unchanged; the diagnostic just makes the shadowing
      # visible so users notice when a later patch is silently masked.
      def duplicate_declaration_diagnostics(entries)
        seen = {}
        entries.each_with_object([]) do |entry, acc|
          key = [entry.class_name, entry.method_name, entry.kind]
          if (first = seen[key])
            acc << build_diagnostic(
              path: entry.source_path,
              line: entry.source_line,
              column: 1,
              severity: :info,
              rule: "pre-eval.duplicate-declaration",
              message: "pre-eval duplicate declaration: " \
                       "#{entry.class_name}##{entry.method_name} " \
                       "(#{entry.kind}) is already declared at " \
                       "#{first.source_path}:#{first.source_line}. " \
                       "The first declaration wins; this entry is shadowed."
            )
          else
            seen[key] = entry
          end
        end
      end
      private_class_method :duplicate_declaration_diagnostics

      # Turns each {PendingAlias} into the entry it publishes, walking the bindings in configuration-then-source
      # order as Ruby runs them. An alias binds to the body its old name has WHEN IT RUNS, so only a `def` or alias
      # earlier in that order may supply its return type: `alias to_m to_modint` after `def to_modint` answers what
      # `to_modint` does, while `alias_method :orig_succ, :succ` ahead of a patch's `def succ` is the method
      # Integer already had. An alias whose old name nothing earlier binds records that name as `alias_of`, for the
      # dispatcher to answer with the class's existing method (`alias old_plus +` on Integer), or with
      # `Dynamic[top]` when nothing knows the name: the alias is still published, since a call to it is not the
      # undefined method a dropped entry would report.
      #
      # Within one file the later binding of a name replaces the earlier, as at runtime: the alias-method-chain
      # idiom (`def foo`, `alias_method :foo_without_x, :foo`, `alias_method :foo, :foo_with_x`) leaves `foo` the
      # alias. Bindings of one name in DIFFERENT files are what `pre-eval.duplicate-declaration` reports, and the
      # registry keeps the first of those, as it always has for `def`s.
      def resolve_aliases(collected)
        bound = {}
        per_file = collected.group_by(&:source_path).values.map do |items|
          final = {}
          items.each do |item|
            entry = item.is_a?(PendingAlias) ? alias_entry(item, bound) : item
            key = [entry.class_name, entry.method_name, entry.kind]
            bound[key] = entry
            final.delete(key)
            final[key] = entry
          end
          final.values
        end
        per_file.flatten(1)
      end
      private_class_method :resolve_aliases

      def alias_entry(item, bound)
        target = bound[[item.class_name, item.old_name, item.kind]]
        ProjectPatchedMethods::Entry.new(
          class_name: item.class_name, method_name: item.new_name, kind: item.kind,
          source_path: item.source_path, source_line: item.source_line,
          return_type: target&.return_type, alias_of: target ? target.alias_of : item.old_name
        )
      end
      private_class_method :alias_entry

      def scan_file(path, entries, diagnostics, buffer = nil, census = Set.new)
        physical = buffer ? buffer.resolve(path) : path
        parse_result =
          if physical == path
            Prism.parse_file(path)
          else
            Prism.parse(File.read(physical), filepath: path)
          end
        unless parse_result.errors.empty?
          diagnostics << parse_error_diagnostic(path, parse_result.errors)
          return
        end

        walk_node(parse_result.value, [], false, path, entries)
        # Issue #1367 — the file's `global.*` write facts: a patch file may alias a special or give a class the
        # method a setter asks for, as any project file may.
        census.merge(GlobalWriteCensus.scan(parse_result.value))
      rescue StandardError => e
        diagnostics << build_diagnostic(
          path: path, line: 1, column: 1,
          severity: :warning,
          rule: "pre-eval.parse-error",
          message: "rigor: failed to read pre_eval entry #{path.inspect}: " \
                   "#{e.class}: #{e.message}. Pre-evaluation skipped for this file; " \
                   "the rest of the run proceeds."
        )
      end
      private_class_method :scan_file

      def parse_error_diagnostic(path, errors)
        first = errors.first
        line = first.respond_to?(:location) ? first.location&.start_line || 1 : 1
        build_diagnostic(
          path: path, line: line, column: 1,
          severity: :warning,
          rule: "pre-eval.parse-error",
          message: "rigor: pre_eval entry #{path.inspect} has a parse error " \
                   "(#{first&.message}). Pre-evaluation skipped for this file; " \
                   "the rest of the run proceeds."
        )
      end
      private_class_method :parse_error_diagnostic

      # Builds a diagnostic Hash-shape the runner translates to a `Rigor::Analysis::Diagnostic`. The
      # scanner intentionally does NOT depend on the analysis layer (it's a pre-pass); the runner
      # adapts at the call site.
      def build_diagnostic(path:, line:, column:, severity:, rule:, message:)
        { path: path, line: line, column: column, severity: severity, rule: rule, message: message }
      end
      private_class_method :build_diagnostic

      def walk_node(node, qualified_prefix, in_singleton_class, source_path, entries)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          descend_class_or_module(node, qualified_prefix, in_singleton_class, source_path, entries)
        when Prism::SingletonClassNode
          descend_singleton_class(node, qualified_prefix, source_path, entries)
        when Prism::DefNode
          record_def_node(node, qualified_prefix, in_singleton_class, source_path, entries)
        when Prism::AliasMethodNode
          record_alias(node, Source::AliasNames.keyword_names(node), qualified_prefix, in_singleton_class,
                       source_path, entries)
        when Prism::CallNode
          record_alias(node, Source::AliasNames.alias_method_call_names(node), qualified_prefix,
                       in_singleton_class, source_path, entries)
          walk_children(node, qualified_prefix, in_singleton_class, source_path, entries)
        else
          walk_children(node, qualified_prefix, in_singleton_class, source_path, entries)
        end
      end
      private_class_method :walk_node

      def walk_children(node, qualified_prefix, in_singleton_class, source_path, entries)
        node.rigor_each_child do |child|
          walk_node(child, qualified_prefix, in_singleton_class, source_path, entries)
        end
      end
      private_class_method :walk_children

      def descend_class_or_module(node, qualified_prefix, in_singleton_class, source_path, entries)
        name = Source::ConstantPath.qualified_name_or_nil(node.constant_path)
        if name && node.body
          child_prefix = Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          walk_node(node.body, child_prefix, in_singleton_class, source_path, entries)
        else
          walk_children(node, qualified_prefix, in_singleton_class, source_path, entries)
        end
      end
      private_class_method :descend_class_or_module

      def descend_singleton_class(node, qualified_prefix, source_path, entries)
        if node.expression.is_a?(Prism::SelfNode) && node.body
          walk_node(node.body, qualified_prefix, true, source_path, entries)
        else
          walk_children(node, qualified_prefix, false, source_path, entries)
        end
      end
      private_class_method :descend_singleton_class

      def record_def_node(node, qualified_prefix, in_singleton_class, source_path, entries)
        return if qualified_prefix.empty?

        class_name = qualified_prefix.join("::")
        kind = node.receiver.is_a?(Prism::SelfNode) || in_singleton_class ? :singleton : :instance
        line = node.location&.start_line || 1
        return_type = Analysis::DependencySourceInference::ReturnTypeHeuristic.extract(node)
        entries << ProjectPatchedMethods::Entry.new(
          class_name: class_name, method_name: node.name, kind: kind,
          source_path: source_path, source_line: line,
          return_type: return_type
        )
      end
      private_class_method :record_def_node

      # `names` is the alias's `[new_name, old_name]`, or nil for a computed name or a call that is not an alias.
      # The side follows the body it is written in, as a `def`'s does: `alias` and `alias_method` inside
      # `class << self` both bind on the singleton.
      def record_alias(node, names, qualified_prefix, in_singleton_class, source_path, entries)
        return if names.nil? || qualified_prefix.empty?

        entries << PendingAlias.new(
          class_name: qualified_prefix.join("::"), new_name: names.first, old_name: names.last,
          kind: in_singleton_class ? :singleton : :instance,
          source_path: source_path, source_line: node.location&.start_line || 1
        )
      end
      private_class_method :record_alias
    end
  end
end
