# frozen_string_literal: true

require "digest"

require_relative "../plugin/template_unit"
require_relative "../type/combinator"
require_relative "diagnostic"

module Rigor
  module Analysis
    # The run's **template units** — the engine side of the ADR-16 Tier-D seam #392 revived (design note
    # `docs/design/20260816-effect-labels.md` § 11.3).
    #
    # Built ONCE, on the parent, before analysis: the loaded plugins' `template_globs:` are expanded, each
    # match's bytes are handed to {Plugin::Base#template_units_for_file}, and what comes back is frozen into
    # this index. Everything after that point is data — `Marshal`-clean Strings and Hashes — so a fork-pool
    # worker analyses a unit from exactly the bytes the parent synthesised and the pooled and sequential
    # paths cannot disagree about what the template said.
    #
    # ## Why the unit is analysed as a file rather than as a synthesised method
    #
    # Wrapping `ruby_source` in a `class … def … end` would shift every line, so the engine would have to
    # compose the plugin's line map with an offset of its own, and a change to the wrapper would silently
    # move every diagnostic. Instead the unit's Ruby is parsed **as-is**, under a per-file {Scope} whose
    # `self_type`, locals and ivars the index seeds directly — the same seeding
    # `StatementEvaluator#build_method_entry_scope` performs at a method boundary, applied at the file
    # boundary. Line 12 of `ruby_source` is line 12 of the parse, and the ONLY mapping in play is the
    # plugin's own.
    #
    # ## What a unit does not participate in
    #
    # `--incremental` dependents. A template unit is synthesised, not read, so nothing in the ADR-46
    # dependency graph names it and an edit to a `.rb` file a unit calls into has no edge back. The
    # conservative reading is taken and stated: **a run always re-analyses every template unit**, which
    # costs a parse per template on the warm incremental path and can never serve a stale answer. Making
    # units first-class dependents is a later slice's work, and needs a decision the design note does not
    # settle.
    class TemplateUnits
      # One synthesised unit, flattened off the plugin's {Plugin::TemplateUnit} with its identity resolved.
      #
      # `path` is both the file the user wrote AND the logical path the engine analyses under: a diagnostic
      # the parse produces already carries it, so nothing has to rewrite a path — only a LINE.
      Entry = Data.define(:logical_name, :path, :source, :line_map, :self_type, :locals, :ivar_seeds,
                          :digest, :unit_key, :plugin_id) do
        # See {Plugin::TemplateUnit#template_line}. Re-implemented on the flattened entry so a worker never
        # needs the plugin value object (or the plugin) to position a diagnostic.
        def template_line(ruby_line)
          return ruby_line if line_map.empty?
          return line_map[ruby_line] if line_map.key?(ruby_line)

          before = line_map.keys.select { |line| line < ruby_line }
          before.empty? ? 1 : line_map[before.max]
        end
      end

      def self.empty
        @empty ||= new({})
      end

      # Expands every loaded plugin's `template_globs:` and runs its transform.
      #
      # A plugin whose glob matches nothing, or whose hook returns `[]`, contributes nothing. A plugin that
      # RAISES contributes nothing and does not break the run — the same failure isolation
      # `#diagnostics_for_file` has, and for the same reason: a template compiler meeting a file it cannot
      # read must cost that file's typing, never the run.
      #
      # Two plugins claiming one path is a conflict with no principled winner, so registration order decides
      # and the later claim is dropped; the loser is not a diagnostic (the project chose both plugins).
      def self.collect(registry:, root: Dir.pwd)
        entries = {}
        registry.plugins.each do |plugin|
          # A plugin whose manifest cannot be read claims nothing. `Plugin::Base#manifest` raises for a
          # class that declared none, and a registry is not guaranteed to hold only well-formed plugins
          # (the loader reports such a failure through its own channel); refusing to glob is the quiet,
          # correct answer here rather than a second report of the same defect.
          globs = begin
            plugin.manifest.template_globs
          rescue StandardError
            []
          end
          next if globs.empty?

          collect_plugin(plugin, globs, root, entries)
        end
        entries.empty? ? empty : new(entries)
      end

      def self.collect_plugin(plugin, globs, root, entries)
        fallback = "#{plugin.manifest.id}@#{plugin.manifest.version}"
        expand(globs, root).each do |path|
          source = begin
            File.binread(File.join(root, path))
          rescue StandardError
            next
          end
          units = begin
            Array(plugin.template_units_for_file(path: path, source: source))
          rescue StandardError
            []
          end
          units.each { |unit| record(entries, unit, fallback, plugin.manifest.id) }
        end
      end
      private_class_method :collect_plugin

      # Sorted so the run's analysed-path order — and therefore the run cache key's `paths` slot — is
      # independent of the filesystem's directory order.
      def self.expand(globs, root)
        globs.flat_map { |glob| Dir.glob(glob, base: root) }
             .uniq.sort
             .select { |path| File.file?(File.join(root, path)) }
      end
      private_class_method :expand

      def self.record(entries, unit, fallback, plugin_id)
        return unless unit.is_a?(Plugin::TemplateUnit)
        return if entries.key?(unit.path)

        entries[unit.path] = Entry.new(
          logical_name: unit.logical_name, path: unit.path, source: unit.ruby_source,
          line_map: unit.line_map, self_type: unit.self_type, locals: unit.locals,
          ivar_seeds: unit.ivar_seeds, digest: unit.digest(fallback), unit_key: unit.unit_key,
          plugin_id: plugin_id
        )
      end
      private_class_method :record

      def initialize(entries)
        @entries = entries.freeze
        freeze
      end

      def empty?
        @entries.empty?
      end

      # The logical paths the run analyses on top of its `.rb` expansion, sorted.
      def paths
        @entries.keys.sort
      end

      def [](path)
        @entries[path]
      end

      def key?(path)
        @entries.key?(path)
      end

      # `{ path => ruby_source }` — what {Runner#parse_source} and {WorkerSession#parse_source} read
      # instead of the bytes on disk.
      def sources
        @entries.transform_values(&:source)
      end

      # The index's cache identity: every unit's digest (source bytes + transform id + synthesis version),
      # keyed by path, hashed once. nil when there are no units, so a project with no template-unit plugin
      # perturbs no cache key at all.
      def digest
        return nil if @entries.empty?

        Digest::SHA256.hexdigest(@entries.keys.sort.map { |path| "#{path}\x00#{@entries[path].digest}" }.join("\n"))
      end

      # The `view:<logical_name>` effect-unit key for a path, or nil.
      def unit_key_for(path)
        @entries[path]&.unit_key
      end

      # Binds the declared `self`, locals and ivar seeds onto the per-file scope, so the unit's body types
      # as the render site would run it. A type name that resolves to nothing is SKIPPED rather than
      # guessed: the binding then stays `Dynamic`, which taints honestly (ADR-5) instead of asserting a
      # class the plugin could not justify.
      def seed(scope, path)
        entry = @entries[path]
        return scope if entry.nil?

        scope = bind_self(scope, entry)
        entry.locals.each do |name, type_name|
          type = resolve(scope, type_name)
          scope = scope.with_local(name.to_sym, type) if type
        end
        entry.ivar_seeds.each do |name, type_name|
          type = resolve(scope, type_name)
          scope = scope.with_ivar(name.to_sym, type) if type
        end
        scope
      end

      # Re-points a diagnostic produced inside a unit at the template's own line. Every other diagnostic
      # passes through untouched, so it is safe to stamp a whole run's stream through this.
      def remap(diagnostics)
        return diagnostics if @entries.empty?

        diagnostics.map do |diagnostic|
          entry = @entries[diagnostic.path]
          next diagnostic if entry.nil?

          line = entry.template_line(diagnostic.line)
          line == diagnostic.line ? diagnostic : relocate(diagnostic, line)
        end
      end

      # The template's lines and the compiled Ruby's columns do not correspond — a compiler preserves lines
      # and rewrites the text of each (Erubi's documented property, and the reason a Rails backtrace can
      # name `show.html.erb:12`). So a remapped diagnostic keeps its line and drops to column 1 rather than
      # pointing at a column of a file whose bytes are not what was analysed.
      def relocate(diagnostic, line)
        Diagnostic.new(
          path: diagnostic.path, line: line, column: 1, message: diagnostic.message,
          severity: diagnostic.severity, rule: diagnostic.rule, source_family: diagnostic.source_family,
          receiver_type: diagnostic.receiver_type, method_name: diagnostic.method_name,
          project_definition_site: diagnostic.project_definition_site
        )
      end

      private

      def bind_self(scope, entry)
        return scope if entry.self_type.nil?

        type = resolve(scope, entry.self_type)
        type ? scope.with_self_type(type) : scope
      end

      def resolve(scope, type_name)
        environment = scope.environment
        resolved = environment&.nominal_for_name(type_name)
        return resolved if resolved
        return nil unless scope.discovered_classes.key?(type_name)

        Type::Combinator.nominal_of(type_name)
      end
    end
  end
end
