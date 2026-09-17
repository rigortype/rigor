# frozen_string_literal: true

require "digest"

require_relative "../cache/descriptor"
require_relative "template_unit_paths"
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
      # What a declared type name binds to when nothing resolves it. `Dynamic[top]` — the analyzer's own
      # "a value is here and I cannot see its class".
      DYNAMIC = Type::Combinator.dynamic(Type::Combinator.top)
      private_constant :DYNAMIC

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
      def self.collect(registry:, root: Dir.pwd, buffer: nil)
        entries = {}
        failures = []
        claimed = []
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

          claimed.concat(globs)
          collect_plugin(plugin, globs, root, entries, failures, buffer)
        end
        new(entries, failures, claimed.uniq, root)
      end

      def self.collect_plugin(plugin, globs, root, entries, failures, buffer)
        id = plugin.manifest.id
        fallback = "#{id}@#{plugin.manifest.version}"
        expand(globs, root, buffer).each do |path|
          source = read_source(physical_path(path, root, buffer), path, id, failures)
          next if source.nil?

          units = begin
            Array(plugin.template_units_for_file(path: path, source: source))
          rescue StandardError => e
            failures << Failure.new(plugin_id: id, path: path,
                                    message: "#{e.class}: #{e.message}")
            next
          end
          units.each { |unit| record(entries, unit, path, fallback, id, failures) }
        end
      end
      private_class_method :collect_plugin

      # Editor mode (#146) — the in-flight buffer's bytes stand in for the file on disk, exactly as
      # `Runner#parse_source` reads them for a `.rb` file. Without this a `--tmp-file` / `--instead-of` pair
      # naming a TEMPLATE compiled the saved file and the editor got diagnostics for bytes it had already
      # replaced. `BufferBinding#resolve` is deliberately NOT used: it compares the logical path by string,
      # and a unit path is project-relative while the editor names its buffer absolutely.
      def self.physical_path(path, root, buffer)
        return buffer.physical_path if buffer && TemplateUnitPaths.relative(buffer.logical_path, root) == path

        File.join(root, path)
      end

      def self.read_source(physical, path, plugin_id, failures)
        File.binread(physical)
      rescue StandardError => e
        failures << Failure.new(plugin_id: plugin_id, path: path,
                                message: "could not be read (#{e.class}: #{e.message})")
        nil
      end
      private_class_method :read_source

      # Sorted so the run's analysed-path order — and therefore the run cache key's `paths` slot — is
      # independent of the filesystem's directory order.
      #
      # An editor buffer whose logical path MATCHES a claimed glob joins the set even when nothing is on
      # disk at that path. That is the `didOpen` of a freshly created view: the file exists only in the
      # editor, `Dir.glob` cannot see it, and without this the run fell through to parsing the tmp bytes as
      # plain top-level Ruby — no declared `self`, no seeds, so a helper call read as
      # `call.unresolved-toplevel` and the finding the editor was actually looking at was missed. The
      # buffer's own bytes are what `collect_plugin` then reads, and nothing else changes: an editor run is
      # read-only-cached, and `Runner#template_unit_file_entries` already skips a path with no physical file.
      def self.expand(globs, root, buffer = nil)
        paths = globs.flat_map { |glob| Dir.glob(glob, base: root) }
                     .select { |path| File.file?(File.join(root, path)) }
        buffered = buffer && TemplateUnitPaths.relative(buffer.logical_path, root)
        paths |= [buffered] if buffered && TemplateUnitPaths.claims?(globs, buffered)
        paths.uniq.sort
      end

      private_class_method :expand

      # A unit MUST name the file it was compiled from. Without the check a `path:` naming another project
      # file silently REPLACED that file's source (the engine serves a unit's bytes for its own path), and a
      # `path:` naming something outside the project root was analysed with no dependency-descriptor row —
      # both from a plugin that only had to get one string wrong. A mismatch is reported, not dropped in
      # silence, because a plugin author whose unit vanished has nothing to read.
      def self.record(entries, unit, claimed_path, fallback, plugin_id, failures)
        return unless unit.is_a?(Plugin::TemplateUnit)

        unless unit.path == claimed_path
          failures << Failure.new(plugin_id: plugin_id, path: claimed_path,
                                  message: "returned a unit for #{unit.path.inspect}, which is not the " \
                                           "file it was offered; a unit may only name its own source")
          return
        end
        # First claim wins — see {.collect}. A duplicate `logical_name` across two DIFFERENT paths is NOT
        # refused: the two units are analysed separately and their summaries union under one `view:` key,
        # which is the same reading a method reopened in two files gets.
        return if entries.key?(unit.path)

        entries[unit.path] = Entry.new(
          logical_name: unit.logical_name, path: unit.path, source: unit.ruby_source,
          line_map: unit.line_map, self_type: unit.self_type, locals: unit.locals,
          ivar_seeds: unit.ivar_seeds, digest: unit.digest(fallback), unit_key: unit.unit_key,
          plugin_id: plugin_id
        )
      end
      private_class_method :record

      # One template file a plugin claimed and did not deliver a usable unit for — a transform that raised,
      # a file that could not be read, or a unit naming the wrong path. Reported as a `plugin_loader`
      # `runtime-error` row by {Runner#template_unit_failure_diagnostics}, which is the isolation envelope
      # every other plugin hook reports through (ADR-2 § "Plugin Trust and I/O Policy").
      Failure = Data.define(:plugin_id, :path, :message)

      def initialize(entries, failures = [], claimed_globs = [], root = Dir.pwd)
        @entries = entries.freeze
        @failures = failures.freeze
        # The globs the loaded plugins claimed, whether or not anything matched. They are the CACHE's
        # business, not the analysis's: see {#glob_entries}.
        @claimed_globs = claimed_globs.freeze
        @root = root
        freeze
      end

      attr_reader :failures

      def empty?
        @entries.empty?
      end

      # The logical paths the run analyses on top of its `.rb` expansion, sorted.
      def paths
        @entries.keys.sort
      end

      def [](path)
        @entries[normalize(path)]
      end

      def key?(path)
        @entries.key?(normalize(path))
      end

      # `{ path => ruby_source }` — what {Runner#parse_source} and {WorkerSession#parse_source} read
      # instead of the bytes on disk.
      def sources
        @entries.transform_values(&:source)
      end

      # The index's cache identity: every unit's digest (source bytes + transform id + synthesis version)
      # keyed by path, plus every FAILURE keyed by path, hashed once. nil only when the run's plugins
      # claimed no globs at all, so a project with no template-unit plugin perturbs no cache key.
      #
      # The failures are in it because a run that produced only failures still produced an ANSWER — one
      # `plugin_loader` row per file — and without them that run's key equalled the no-templates key. A
      # later run whose template now compiles, or whose template is gone, reconstructed the same key, and
      # the ADR-87 boot-slim probe (which loads no plugin, so its slot is always absent) served the stale
      # rows. The slot now exists whenever any plugin claimed a glob, which is exactly the condition under
      # which the probe's key is knowingly unreconstructable.
      def digest
        return nil if @claimed_globs.empty?

        rows = @entries.keys.sort.map { |path| "unit\x00#{path}\x00#{@entries[path].digest}" } +
               @failures.map { |failure| "fail\x00#{failure.path}\x00#{failure.message}" }.sort
        Digest::SHA256.hexdigest((["globs\x00#{@claimed_globs.sort.join("\x00")}"] + rows).join("\n"))
      end

      # The ADR-60 WD3 / #979 `:names` glob rows the run's dependency descriptor records: one per claimed
      # pattern, whether or not it matched.
      #
      # Without them a template APPEARING under a claimed glob moved nothing a warm run could see — the
      # descriptor listed only the files that already existed — so a project whose first template was added
      # between two runs kept replaying the answer computed before it existed. `:names` rather than `:stat`
      # for the same reason the signature roots use it (`cache.md` § the run-descriptor row inventory): the
      # question a glob row adds is which files MATCH, and edits to those files are carried by their own
      # file rows.
      def glob_entries
        @claimed_globs.map do |pattern|
          Cache::Descriptor::GlobEntry.compute(root: @root.to_s, pattern: pattern, mode: :names)
        end
      end

      # Every template file this run read — the ones that produced a unit AND the ones that failed. A
      # failure's file is as much an input to the run's answer as a success's: the `plugin_loader` row it
      # produced must not outlive the edit that fixes the template.
      def source_paths
        (@entries.keys + @failures.map(&:path)).uniq.sort
      end

      # The Prism `scopes:` argument for a unit's parse, or nil for a path that is not one.
      #
      # Without it the seeded locals are inert: Prism parses a bare identifier with no assignment in sight
      # as a **method call**, so `size` in a template was a `CallNode` and `Scope#local(:size)` was never
      # consulted. Declaring the render site's locals as an enclosing scope is exactly what Rails does when
      # it compiles a partial's locals into the method's parameters, and it is what makes `locals:` mean
      # anything.
      def parse_scopes(path)
        entry = @entries[normalize(path)]
        return nil if entry.nil? || entry.locals.empty?

        [entry.locals.keys.map(&:to_sym)]
      end

      # The `view:<logical_name>` effect-unit key for a path, or nil.
      # The file whose bytes a unit's path was READ from: the editor's buffer when one is bound to it, the
      # project file otherwise. Read by the run's dependency descriptor, so it digests what the run read.
      def physical_path(path, buffer)
        self.class.physical_path(path, @root, buffer)
      end

      def unit_key_for(path)
        @entries[normalize(path)]&.unit_key
      end

      # Binds the declared `self`, locals and ivar seeds onto the per-file scope, so the unit's body types
      # as the render site would run it.
      #
      # A type name that resolves to nothing is bound `Dynamic` rather than guessed OR left unbound, and
      # the difference matters most for `self_type:`. Leaving it unbound is not "no claim": it is the claim
      # that the body runs at top level, so every helper call in the template reports
      # `call.unresolved-toplevel` — a finding per line, caused by the plugin naming a class whose RBS the
      # project does not ship (`ActionView::Base`, on the very first Rails app to try this). `Dynamic` is
      # the honest reading of "a receiver is declared and the analyzer cannot see it" (ADR-5), and it is
      # silent.
      def seed(scope, path)
        entry = @entries[normalize(path)]
        return scope if entry.nil?

        scope = bind_self(scope, entry)
        entry.locals.each do |name, type_name|
          scope = scope.with_local(name.to_sym, resolve(scope, type_name))
        end
        entry.ivar_seeds.each do |name, type_name|
          scope = scope.with_ivar(name.to_sym, resolve(scope, type_name))
        end
        scope
      end

      # Re-points a diagnostic produced inside a unit at the template's own line. Every other diagnostic
      # passes through untouched, so it is safe to stamp a whole run's stream through this.
      def remap(diagnostics)
        return diagnostics if @entries.empty?

        diagnostics.map do |diagnostic|
          entry = @entries[normalize(diagnostic.path)]
          next diagnostic if entry.nil?

          next diagnostic if entry.line_map.empty?

          relocate(diagnostic, entry.template_line(diagnostic.line))
        end
      end

      # The template's lines and the compiled Ruby's columns do not correspond — a compiler preserves lines
      # and rewrites the text of each (Erubi's documented property, and the reason a Rails backtrace can
      # name `show.html.erb:12`). So a diagnostic from a unit keeps its line and drops to column 1 rather
      # than pointing at a column of a file whose bytes are not what was analysed.
      #
      # Applied whenever the unit carries a map, NOT only when the line moves: a compiler that happens to
      # leave a line where it was still rewrote that line's text, and ERB is exactly that case — the map is
      # near-identity and the columns are meaningless anyway.
      def relocate(diagnostic, line)
        Diagnostic.new(
          path: diagnostic.path, line: line, column: 1, message: diagnostic.message,
          severity: diagnostic.severity, rule: diagnostic.rule, source_family: diagnostic.source_family,
          receiver_type: diagnostic.receiver_type, method_name: diagnostic.method_name,
          project_definition_site: diagnostic.project_definition_site
        )
      end

      private

      def normalize(path)
        TemplateUnitPaths.relative(path, @root)
      end

      def bind_self(scope, entry)
        return scope if entry.self_type.nil?

        scope.with_self_type(resolve(scope, entry.self_type))
      end

      def resolve(scope, type_name)
        environment = scope.environment
        resolved = environment&.nominal_for_name(type_name)
        return resolved if resolved
        return DYNAMIC unless scope.discovered_classes.key?(type_name)

        Type::Combinator.nominal_of(type_name)
      end
    end
  end
end
