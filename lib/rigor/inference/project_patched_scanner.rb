# frozen_string_literal: true

require "prism"

require_relative "project_patched_methods"
require_relative "../analysis/dependency_source_inference/return_type_heuristic"

module Rigor
  module Inference
    # ADR-17 slice 2 — pre-pass scanner. Walks every file the user
    # listed under `pre_eval:` and harvests every `def` /
    # `def self.` declaration inside a class / module body into a
    # {ProjectPatchedMethods} registry the dispatcher consults
    # below the plugin tier.
    #
    # The walker is intentionally a strict subset of
    # {Rigor::Inference::ScopeIndexer}'s machinery: it only needs
    # `class C; def m; end; end` shape recognition, not full
    # inference. Parse errors degrade to a fail-soft `:warning`
    # `pre-eval.parse-error` diagnostic accumulated alongside
    # the registry; per ADR-17 § "Failure modes" a parse failure
    # in a pre-eval file MUST NOT abort the rest of the run.
    module ProjectPatchedScanner
      # Frozen scan outcome carrying the populated registry and
      # the per-file warnings the runner emits at run start.
      class Result < Data.define(:registry, :diagnostics)
        def initialize(registry:, diagnostics: [])
          super(
            registry: registry,
            diagnostics: diagnostics.freeze
          )
        end
      end

      module_function

      # @param paths [Array<String>] absolute paths to the
      #   pre-eval files. The runner has already validated that
      #   each path exists (slice-1 `pre-eval.file-not-found`
      #   `:error` covers missing entries); the scanner does NOT
      #   re-check existence.
      # @param buffer [Rigor::Analysis::BufferBinding, nil]
      #   editor-mode buffer binding. When set, the scanner reads
      #   the buffer's physical bytes if a pre-eval entry matches
      #   the logical path, so users editing a monkey-patch file
      #   see the in-flight version in their analysis.
      # @return [Result] the populated registry plus any
      #   per-file warnings.
      def scan(paths, buffer: nil)
        entries = []
        diagnostics = []
        paths.each { |path| scan_file(path, entries, diagnostics, buffer) }
        diagnostics.concat(duplicate_declaration_diagnostics(entries))
        Result.new(
          registry: ProjectPatchedMethods.new(entries: entries),
          diagnostics: diagnostics
        )
      end

      # ADR-17 § "Failure modes" — when two pre-eval entries
      # declare the same `(class_name, method_name, kind)` triple,
      # emit one `:info` `pre-eval.duplicate-declaration`
      # diagnostic per collision. The registry's first-write-wins
      # behaviour is unchanged; the diagnostic just makes the
      # shadowing visible so users notice when a later patch
      # is silently masked.
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

      def scan_file(path, entries, diagnostics, buffer = nil)
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

      # Builds a diagnostic Hash-shape the runner translates to a
      # `Rigor::Analysis::Diagnostic`. The scanner intentionally
      # does NOT depend on the analysis layer (it's a pre-pass);
      # the runner adapts at the call site.
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
        else
          walk_children(node, qualified_prefix, in_singleton_class, source_path, entries)
        end
      end
      private_class_method :walk_node

      def walk_children(node, qualified_prefix, in_singleton_class, source_path, entries)
        node.compact_child_nodes.each do |child|
          walk_node(child, qualified_prefix, in_singleton_class, source_path, entries)
        end
      end
      private_class_method :walk_children

      def descend_class_or_module(node, qualified_prefix, in_singleton_class, source_path, entries)
        name = qualified_name_for(node.constant_path)
        if name && node.body
          walk_node(node.body, qualified_prefix + [name], in_singleton_class, source_path, entries)
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
