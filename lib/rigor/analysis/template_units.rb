# frozen_string_literal: true

require "digest"

require_relative "../cache/descriptor"
require_relative "template_unit_collector"
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
    #
    # ## Carrying an index across runs (#1038)
    #
    # A long-lived {LanguageServer::ProjectContext} holds one warm {ProjectScan}, which carries the index it
    # built, and every per-buffer publish hands it back through `collect(previous:)`. A path whose template
    # has not moved on disk REUSES the unit already compiled for it, so a keystroke runs no plugin code —
    # for ERB (#393) that is an Erubi compile of every view in the project, per keystroke, which is what
    # this exists to remove. What is re-done per run is cheap and is what notices a change: the globs are
    # re-expanded (only a glob notices a template APPEARING or vanishing) and each surviving path is
    # revalidated through the ADR-87 stat-then-digest choke point ({Cache::FileDigest.stat_fresh?}), whose
    # authority is the content digest, not the stat tuple. Three things rebuild the index outright, because
    # each can change what a transform produces for bytes that never moved: a different root, a different
    # set of claimed globs, and a different set of glob-claiming plugins.
    #
    # A fourth rebuilds one PLUGIN'S claim outright (#1047): any of that plugin's templates edited, added or
    # deleted (except the deletion of a template that had produced no unit, which the carried rows cannot
    # attribute to a plugin and which contributed nothing a sibling could read). A transform may read the
    # plugin's other templates — rigor-actionpack seeds a partial's locals from the views that render it —
    # so the freshness of `_card` alone cannot vouch for `_card`'s unit. The editor's buffer does not count
    # as an edit, so this never costs a keystroke, and it bites only on an on-disk edit the owner has not
    # invalidated for — a save already rebuilds cold. A template read with no unit (declined, or raised) is
    # carried as a bare stat pack for exactly this decision, so an unchanged declined file is not mistaken
    # for an edit.
    #
    # Separately, and whatever the rest of the index does, the editor's own buffer is never carried: a
    # path the buffer is bound to is recompiled from the buffer's bytes on every publish, and the compiled
    # result stays in THAT run's index — the warm index on the ProjectScan only ever holds units compiled
    # from files on disk. A template the plugin DECLINES, or whose transform raised, likewise produces no
    # unit to carry and is re-offered every run.
    #
    # A sequential CLI run passes no `previous:` and so builds the index from scratch exactly as before: it
    # has no warm index to carry, its process ends with the run, and adding a cross-process memo would be a
    # second cache to prove sound for no measurable gain (the index is built once per `rigor check`).
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
                          :digest, :unit_key, :plugin_id, :suppressed_rules) do
        # #393 — the per-unit rule posture. True when the plugin declared that this family of finding is
        # not meaningful in its compiled output.
        def suppresses?(rule)
          return false if rule.nil? || suppressed_rules.empty?

          suppressed_rules.any? { |prefix| rule.to_s.start_with?(prefix) }
        end

        # See {Plugin::TemplateUnit#template_line}. Re-implemented on the flattened entry so a worker never
        # needs the plugin value object (or the plugin) to position a diagnostic.
        def template_line(ruby_line)
          return ruby_line if line_map.empty?
          return line_map[ruby_line] if line_map.key?(ruby_line)

          before = line_map.keys.select { |line| line < ruby_line }
          before.empty? ? 1 : line_map[before.max]
        end
      end

      # The index a run with no template-claiming plugin analyses under. Eagerly built on the main Ractor
      # at load time (bottom of the class body) rather than memoised on first use: `@empty ||= new({})` is
      # a class-ivar WRITE, which a non-main Ractor may not perform. {WorkerSession#initialize} reaches it
      # whenever `template_units:` is not supplied, which is exactly how the Ractor backend constructs its
      # workers — so the lazy memo killed every worker in its constructor and degraded every run (#1055).
      class << self
        attr_reader :empty
      end

      # Expands every loaded plugin's `template_globs:` and runs its transform. The work lives in
      # {TemplateUnitCollector}, which owns the glob expansion, the failure isolation, the editor-buffer
      # substitution and the #1038 carry; this class is what the rest of the run READS.
      #
      # @param previous — a warm index from an earlier run of the same project (#1038). Every unit in it
      #   whose template is unchanged on disk is carried over instead of recompiled; see the class note.
      def self.collect(registry:, root: Dir.pwd, buffer: nil, previous: nil)
        TemplateUnitCollector.collect(registry: registry, root: root, buffer: buffer, previous: previous)
      end

      # One template file a plugin claimed and did not deliver a usable unit for — a transform that raised,
      # a file that could not be read, or a unit naming the wrong path. Reported as a `plugin_loader`
      # `runtime-error` row by {Runner#template_unit_failure_diagnostics}, which is the isolation envelope
      # every other plugin hook reports through (ADR-2 § "Plugin Trust and I/O Policy").
      Failure = Data.define(:plugin_id, :path, :message)

      def initialize(entries, failures: [], claimed_globs: [], root: Dir.pwd, stats: {},
                     plugin_signature: [])
        @entries = entries.freeze
        @failures = failures.freeze
        # The globs the loaded plugins claimed, whether or not anything matched. They are the CACHE's
        # business, not the analysis's: see {#glob_entries}.
        @claimed_globs = claimed_globs.freeze
        @root = root
        # #1038 — the freshness token per template this index READ successfully: the ADR-87
        # `(digest, size, mtime_ns, ctime_ns, inode)` pack over the bytes the transform was handed. Not part
        # of the index's own identity ({#digest}) — a stat is not an answer, only the question of whether a
        # carried answer still holds.
        @stats = stats.freeze
        @plugin_signature = plugin_signature.freeze
        freeze
      end

      attr_reader :failures

      # #1038 — the `{ path => [entry, stat_pack] }` a later run may reuse, or `{}` when the whole index has
      # to be rebuilt. The three whole-index refusals live here rather than per path because each of them
      # can change what a transform PRODUCES for a template whose bytes never moved: a different root is a
      # different project, a different claim set can hand a path to a different plugin, and a different
      # plugin set is different code.
      def carry_over(root:, claimed_globs:, plugin_signature:)
        return {} unless @root.to_s == root.to_s
        return {} unless @claimed_globs == claimed_globs
        return {} unless @plugin_signature == plugin_signature

        # A template that was READ but produced no unit (declined, or its transform raised) is carried as
        # `[nil, pack]`: there is no unit to reuse, but its freshness still answers whether it CHANGED, which
        # is what the collector's whole-claim decision needs (#1047) — without it one declined template
        # would read as an edit on every run and cost the whole claim its carry.
        @stats.each_with_object({}) do |(path, packed), carried|
          carried[path] = [@entries[path], packed] if packed
        end
      end

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
        TemplateUnitCollector.physical_path(path, @root, buffer)
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

      # Re-points a diagnostic produced inside a unit at the template's own line, and drops the ones the
      # unit's plugin declared it does not report (#393). Every other diagnostic passes through untouched,
      # so it is safe to stamp a whole run's stream through this.
      #
      # The suppression is per unit rather than global because it is a claim about ONE compiler's output:
      # a plugin whose synthesised receivers are still coarse suppresses `call.` so the view layer can be
      # analysed for its EFFECTS — which need no receiver precision — without the typing half costing the
      # project a diagnostic per template line. It is deliberately not a `disable:` entry: `disable:` would
      # silence the rule in the project's `.rb` files too, which is the opposite of what is wanted.
      def remap(diagnostics)
        return diagnostics if @entries.empty?

        diagnostics.filter_map do |diagnostic|
          entry = @entries[normalize(diagnostic.path)]
          next diagnostic if entry.nil?
          next nil if entry.suppresses?(diagnostic.rule)
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

      # Populates the `@empty` singleton on the main Ractor at load time. `Ractor.make_shareable` rather
      # than `freeze` so a worker's READ of the class ivar is legal too: a non-main Ractor may read a
      # class/module ivar only when the value is deeply shareable, and `#initialize` freezes the index
      # itself but leaves `@root` — a fresh `Dir.pwd` String — unfrozen. The baked root is inert here: an
      # index with no entries and no claimed globs answers nothing and carries nothing over.
      @empty = Ractor.make_shareable(new({}))
    end
  end
end
