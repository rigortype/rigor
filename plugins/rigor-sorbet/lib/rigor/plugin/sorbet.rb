# frozen_string_literal: true

require "prism"
require "rigor/plugin"

require_relative "sorbet/method_signature"
require_relative "sorbet/catalog"
require_relative "sorbet/type_translator"
require_relative "sorbet/sig_parser"
require_relative "sorbet/catalog_walker"
require_relative "sorbet/assertion_recognizer"
require_relative "sorbet/absurd_recognizer"
require_relative "sorbet/sigil_detector"

module Rigor
  module Plugin
    # rigor-sorbet — ingests Sorbet `sig { ... }` blocks as method-signature contributions to Rigor's
    # analyzer.
    #
    # ADR-11 slice 1 — first deliverable. Recognises:
    #
    # - `sig { params(x: Integer).returns(String) }` above a `def foo(x)` definition, contributing the
    #   parsed return type at every call site.
    # - The `void` terminus and the `abstract` / `override` / `overridable` / `final` modifiers (recorded
    #   on the {MethodSignature} for slice ≥2).
    # - `class Foo` / `module Foo::Bar` / `class << self` nesting; `def self.foo` is recognised as a
    #   singleton method.
    #
    # The {TypeTranslator} table documents coverage. Most of Sorbet's vocabulary translates; remaining
    # gaps (`T.proc`, `T::Struct` subclasses, `T.attached_class`, etc.) degrade silently to `Dynamic[top]`.
    #
    # Architecture: per-run `Catalog` is built lazily on first access by walking every configured `paths:`
    # entry's `.rb` files plus every `rbi_paths:` entry's `.rbi` files (slice 4) via the plugin's
    # `IoBoundary`. The catalog is frozen after the first build and consulted by the `dynamic_return` rule
    # at every gated call site. RBI files share the catalog with project-source sigs — both produce
    # `MethodSignature` entries keyed by `(class_name, method_name, kind)`. When a key collides across
    # files, the last-walked sig wins (ordering is platform-dependent: `Dir.glob` returns directory
    # entries in filesystem order). Sorbet's full shim-override semantics — `sorbet/rbi/shims/` overriding
    # `sorbet/rbi/gems/` — lands in a later slice once the catalog gains per-source provenance.
    #
    # The plugin emits `plugin.sorbet.parse-error` warnings for malformed sig blocks (no block / empty
    # block / no `returns` or `void` terminus / two consecutive sigs / sig not followed by a def) but
    # never aborts a run.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-sorbet
    #         config:
    #           paths: ["lib", "app"]         # directories to scan for `.rb` sigs; defaults to `paths:`
    #           rbi_paths: ["sorbet/rbi"]     # directories to scan for `.rbi` files; default shown
    #
    # The `paths:` config key narrows the plugin's `.rb` walk; omit it to inherit the project-wide
    # `paths:` value. The `rbi_paths:` key controls where Sorbet's RBI tree is read from — defaults to
    # `sorbet/rbi/` per Tapioca's standard layout (`gems/`, `annotations/`, `dsl/`, `shims/`). Set to `[]`
    # to opt out of RBI loading entirely.
    class Sorbet < Rigor::Plugin::Base
      manifest(
        id: "sorbet",
        version: "0.1.0",
        description: "Ingests Sorbet `sig` blocks as method-signature contributions.",
        config_schema: {
          # `paths` keeps a `fetch`-with-default in `init` because its default is dynamic (the project's
          # configured `paths`), not a static literal the manifest can declare.
          "paths" => :array,
          # Default RBI directory tree. Matches the layout `tapioca init` generates — see Sorbet's
          # `rbi.md`. Slice 4 walks every `.rbi` file under these roots recursively; the four standard
          # Tapioca subdirectories (`gems` / `annotations` / `dsl` / `shims`) are picked up as a side
          # effect of recursing into the parent root.
          "rbi_paths" => { kind: :array, default: ["sorbet/rbi"] },
          "enforce_sigil" => { kind: :boolean, default: true }
        }
      )

      def init(services)
        @services = services
        @configured_paths = Array(config.fetch("paths", services.configuration.paths)).map(&:to_s)
        @rbi_paths = Array(config.fetch("rbi_paths")).map(&:to_s)
        # Schema default `true` — only files marked `# typed: true` / `:strict` / `:strong` contribute
        # their sigs. Set to `false` to record every file's sigs regardless of sigil (current behaviour
        # pre-this-config).
        @enforce_sigil = config.fetch("enforce_sigil")
        # Per-call-site assertion gating: `@sigil_by_path` (built during catalog harvest) is consulted so
        # `T.let` / `T.cast` / `T.must` / `T.bind` / `T.assert_type!` only fire in files Sorbet itself
        # would enforce (`:true` / `:strict` / `:strong`). With `enforce_sigil: false` the gate is open
        # everywhere. Missing-sigil paths (synthetic fixtures, out-of-tree call sites) default to enforced
        # — failing-open suits spec ergonomics better than failing-closed. See `assertion_enforced_here?`.
        @sigil_by_path = {}
        @catalog = nil
        @parse_errors_by_path = {}
        @catalog_built = false
        # ADR-11 slice 6 — Prism nodes for `T.absurd` calls we observed in the `dynamic_return` rule to be
        # *reachable* (i.e., their discriminant didn't narrow to `bot`). `diagnostics_for_file` walks the
        # per-file AST and surfaces these as `plugin.sorbet.absurd-reachable` warnings. Hash is keyed on
        # the Prism node's `object_id` because the runner only parses each file once per run, so identity
        # is stable across the two plugin hooks.
        @reachable_absurd_nodes = {}.compare_by_identity
        # ADR-11 light follow-up — `T.reveal_type` calls observed in the `dynamic_return` rule, paired
        # with the display string for the inferred type at the call site. Mirrors the absurd-node
        # compare-by-identity hash; `diagnostics_for_file` surfaces each entry as a
        # `plugin.sorbet.reveal-type` `:info` diagnostic.
        @reveal_type_calls = {}.compare_by_identity
        # T.bind / T.assert_type! priority slice 1 — `T.assert_type!` calls observed in the
        # `dynamic_return` rule whose static subtype check FAILED, paired with the inferred + asserted
        # type display strings. Same compare-by-identity discipline. `diagnostics_for_file` walks the
        # file AST for `T.assert_type!` calls and surfaces matching entries as
        # `plugin.sorbet.assert-type-mismatch` `:error` diagnostics.
        @assert_type_mismatches = {}.compare_by_identity
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        ensure_catalog
        # The catalog records errors under the canonicalised (realpath-resolved) form; the runner may pass
        # the symlink-bearing form here. Look up under both so the match is symlink-agnostic.
        errors = @parse_errors_by_path[path] || @parse_errors_by_path[canonicalize(path)] || []
        errors.map { |error| parse_error_diagnostic(path, error) }
      end

      # ADR-88 WD2 — the per-run catalog is an ADR-60 record-and-validate producer. Before this it was rebuilt
      # unconditionally on every `--incremental` recheck (parse + walk every `.rb` / `.rbi` sig tree); as a
      # producer it is cached to disk keyed on the plugin config, with `watch:` covering the scanned trees so an
      # added / removed / edited sig file recomputes it. The producer VALUE (a Marshal-clean bundle of the
      # catalog + the sigil map + the parse-error tuples) is what ADR-88 WD1 digests into the incremental
      # fact-surface fingerprint, so a sig edit OUTSIDE `signature_paths:` invalidates the snapshot for free.
      # The bundle is returned (not written to ivars) because a cache HIT does not run the block — the sigil map
      # and parse errors would otherwise be lost on the warm path.
      producer :catalog, watch: -> { catalog_watch_globs } do |_params|
        build_catalog_bundle
      end

      # ADR-52 slice 4 — per-call return-type path via the method-name-gated `dynamic_return` DSL. The
      # recognised name set is only known at run time (the catalog's `def` names come from the lazy
      # catalog build), so it is declared as a callable: the engine `instance_exec`s it once per run on
      # first dispatch (always after `#prepare`) and memoises the resolved Symbol Set. The gate is a safe
      # over-approximation — a project method merely *named* `cast` or `find` passes it and is declined by
      # the block's own `T.`-receiver / catalog checks.
      dynamic_return methods: -> { recognised_method_names } do |call_node, scope|
        contribution_return_type(call_node, scope)
      end

      # ADR-52 slice 4 — `T.bind(self, T)`'s self-narrowing fact, contributed via the method-gated
      # `narrowing_facts` DSL. The statement evaluator consults this path for narrowing facts. The
      # return-type half (`Constant[nil]`) flows through the `dynamic_return` rule above; the block
      # re-checks the `T.` receiver via the recogniser, so an unrelated `bind` call contributes nothing.
      narrowing_facts methods: [:bind] do |call_node, scope|
        bind_post_return_facts(call_node, scope)
      end

      # ADR-37 — the three per-call diagnostics ride the engine-owned walk instead of three hand-rolled
      # `walk_for_*` recursions. Each candidate `T.` call is *recorded by object identity* during the
      # inference pass (the `dynamic_return` / `narrowing_facts` rules above call `record_*`), so by the
      # time these node rules fire in the diagnostics phase the sets are populated; the membership
      # `delete` both gates the emission and pops the entry so a re-run cannot double-fire. The recorded
      # set is the gate — no per-node `AbsurdRecognizer` / name check is needed here.
      node_rule Prism::CallNode do |node, _scope, path|
        next [] unless @reachable_absurd_nodes.delete(node)

        [absurd_diagnostic(path, node)]
      end

      node_rule Prism::CallNode do |node, _scope, path|
        display = @reveal_type_calls.delete(node)
        next [] if display.nil?

        [reveal_type_diagnostic(path, node, display)]
      end

      node_rule Prism::CallNode do |node, _scope, path|
        recorded = @assert_type_mismatches.delete(node)
        next [] if recorded.nil?

        [assert_type_mismatch_diagnostic(path, node, *recorded)]
      end

      private

      # Run-time method-name gate for the `dynamic_return` rule (ADR-52 slice 4): the static assertion
      # vocabulary (`T.let` / `T.cast` / …), `T.absurd`, and every method name the catalog carries a sig for.
      def recognised_method_names
        ensure_catalog
        names = AssertionRecognizer::SORBET_ASSERTIONS.dup
        names << :absurd
        names.concat(@catalog.method_names)
        names
      end

      # Main contribution body for the `dynamic_return` rule. Returns the bare `Rigor::Type` the contract
      # expects. Resolves the receiver in three passes:
      #
      # 1. Constant receiver (`User.find(...)`) → singleton-side catalog lookup.
      # 2. Nominal receiver-type (`user.name` where `user`'s inferred type is `Nominal["User"]`) →
      #    instance-side catalog lookup.
      # 3. Implicit-self (receiver-less inside a method body) → current-class lookup via
      #    `implicit_self_lookup`.
      def contribution_return_type(call_node, scope)
        return nil unless call_node.is_a?(Prism::CallNode)

        # ADR-11 slice 6 — `T.absurd(x)` exhaustiveness. Always contributes a `bot` return (matches
        # Sorbet's runtime behaviour: `T.absurd` raises, so its value type is `bot` and the engine's flow
        # analysis treats code after it as unreachable; the legacy contribution's `exceptional: :raises`
        # slot was never consumed on the dispatcher path — only `return_type` survives the merge). When
        # the discriminant *isn't* narrowed to `bot` at this scope, also records the call node so
        # `diagnostics_for_file` can surface a `plugin.sorbet.absurd-reachable` warning.
        if AbsurdRecognizer.absurd_call?(call_node)
          @reachable_absurd_nodes[call_node] = true unless AbsurdRecognizer.exhaustive?(call_node, scope)
          return Rigor::Type::Combinator.bot
        end

        # ADR-11 slice 2 — `T.let` / `T.cast` / `T.must` / `T.unsafe` are checked first because they're
        # cheaper to recognise (no catalog walk required) and they win over any cataloged signature: the
        # user explicitly asserted the type at the call site. The light follow-up extends the recogniser
        # to `T.must_because` (alias of `T.must`) and `T.reveal_type` (passes the type through; the
        # human-facing diagnostic is recorded here for `diagnostics_for_file` to emit).
        #
        # Per-call-site sigil gating: with `enforce_sigil: true` (default), assertions only fire in files
        # Sorbet itself would enforce. Files at `# typed: false` (or sigil-less, which Sorbet treats as
        # `:false`) skip the assertion path entirely so the dispatcher continues through the next tier as
        # if the wrapper weren't there. The catalog tier already gates by sigil at harvest time; this
        # closes the matching gap for caller-side recognition.
        ensure_catalog
        if assertion_enforced_here?(scope)
          assertion = AssertionRecognizer.recognize(
            call_node: call_node, scope: scope, plugin_id: manifest.id
          )
          if assertion
            record_reveal_type_call(call_node, assertion.return_type) if call_node.name == :reveal_type
            record_assert_type_check(call_node, scope) if call_node.name == :assert_type!
            return assertion.return_type
          end
        end

        return nil if @catalog.nil? || @catalog.empty?

        lookup_signature(call_node, scope)&.return_type
      end

      # The `narrowing_facts` body for `T.bind` — same sigil gate as the return-type path, then the
      # recogniser's `post_return_facts` (the `Fact(target_kind: :self)` that narrows `scope.self_type`
      # for the rest of the block).
      def bind_post_return_facts(call_node, scope)
        return nil unless call_node.is_a?(Prism::CallNode)

        ensure_catalog
        return nil unless assertion_enforced_here?(scope)

        contribution = AssertionRecognizer.recognize(
          call_node: call_node, scope: scope, plugin_id: manifest.id
        )
        contribution&.post_return_facts
      end

      # Per-call-site assertion gating (ADR-11). With `enforce_sigil: false` the gate is fully open. With
      # `enforce_sigil: true` (default), the caller file's sigil must reach `:true` / `:strict` /
      # `:strong` for assertions to fire. Three honest fallbacks:
      #
      # - `scope.source_path` is nil — synthetic call sites (specs, virtual-node fixtures) have no file
      #   context. Default to enforced so existing recogniser tests keep working.
      # - the path is canonicalised to a form not in `@sigil_by_path` — the harvest never saw this file
      #   (out-of-tree call site, or a path the `configured_paths` config excluded). Sorbet itself has no
      #   opinion on such files; default to enforced so the recogniser still fires.
      # - the path IS in `@sigil_by_path` but at `:false` / `:ignore` — gate closes.
      def assertion_enforced_here?(scope)
        return true unless @enforce_sigil

        path = scope&.source_path
        return true if path.nil?
        return true unless @catalog_built

        level = @sigil_by_path[path] || @sigil_by_path[canonicalize(path)]
        return true if level.nil?

        SigilDetector.enforced?(level)
      end

      def lookup_signature(call_node, scope)
        receiver = call_node.receiver
        method_name = call_node.name
        return nil if method_name.nil?

        if (singleton_target = constant_receiver_name(receiver))
          # `Post.find(...)` — direct singleton method, or `extend M` lifting `M#find` to the extending
          # class.
          chain_lookup(singleton_target, method_name, anchor_kind: :singleton, mixin_kind: :extend)
        elsif receiver
          instance_chain_lookup(receiver, method_name, scope)
        else
          implicit_self_lookup(method_name, scope)
        end
      end

      # ADR-11 slice 2 — implicit-self calls.
      # A receiver-less call inside a method body resolves against the engine's own `scope.self_type`:
      # `Nominal[Foo]` inside an instance method (instance-side lookup), `Singleton[Foo]` inside a `def
      # self.x` body (singleton-side lookup, `extend` mixins). Without this, an enforced sig on a sibling
      # method was invisible to in-class calls — the engine's body-inference tiers then re-typed the
      # sibling's body, overriding an explicit `T.untyped` opt-out (the dispatcher's plugin tier had
      # already run and declined). Anything else (toplevel / Dynamic / DSL self) contributes nothing and
      # the dispatcher continues.
      def implicit_self_lookup(method_name, scope)
        self_type = scope&.self_type
        case self_type
        when Rigor::Type::Singleton
          chain_lookup(self_type.class_name, method_name, anchor_kind: :singleton, mixin_kind: :extend)
        when Rigor::Type::Nominal
          chain_lookup(self_type.class_name, method_name, anchor_kind: :instance, mixin_kind: :include)
        end
      rescue StandardError
        nil
      end

      def instance_chain_lookup(receiver_node, method_name, scope)
        return nil if scope.nil?

        receiver_type = scope.type_of(receiver_node)
        return nil unless receiver_type.is_a?(Rigor::Type::Nominal)

        chain_lookup(receiver_type.class_name, method_name, anchor_kind: :instance, mixin_kind: :include)
      rescue StandardError
        # `scope.type_of` can raise on unrecognised synthetic nodes; degrade to "no contribution" rather
        # than bubbling the failure into the dispatcher.
        nil
      end

      # ADR-11 slice 8 — chain-aware catalog lookup.
      #
      # For instance-side calls (`post.body`):
      # - `anchor_kind: :instance` (try `Post#body` first)
      # - `mixin_kind: :include` (then walk Post's `include`d modules and try `Foo#body` on each)
      #
      # For singleton-side calls (`Post.find`):
      # - `anchor_kind: :singleton` (try `Post.find` first)
      # - `mixin_kind: :extend` (then walk Post's `extend`ed modules and try `Foo#find` *as :instance* —
      #   `extend Foo` lifts Foo's INSTANCE methods to the extending class's SINGLETON methods, matching
      #   Ruby's MRO).
      def chain_lookup(class_name, method_name, anchor_kind:, mixin_kind:)
        each_class_form(class_name).each do |form|
          sig = @catalog.lookup(class_name: form, method_name: method_name, kind: anchor_kind)
          return sig if sig
        end

        visited = Set.new
        queue = mixin_modules_for(class_name, mixin_kind).dup

        until queue.empty?
          candidate = queue.shift
          next unless visited.add?(candidate)

          forms_for_mixin(class_name, candidate).each do |form|
            sig = @catalog.lookup(class_name: form, method_name: method_name, kind: :instance)
            return sig if sig

            # Transitive: an `include` inside the mixed-in module is also inherited by the host class.
            mixin_modules_for(form, :include).each do |inner|
              queue << inner unless visited.include?(inner)
            end
          end
        end

        nil
      end

      # `Post` and `::Post` are routinely confused at the catalog boundary (the walker records the lexical
      # name; user code often writes the rooted form). Try both at every lookup.
      def each_class_form(class_name)
        [class_name, "::#{class_name}"]
      end

      # Resolution forms for a mixed-in module name. Tapioca's generated DSL RBIs use the nested form
      # (`class Post; module GeneratedAttributeMethods; ...; end`); hand-written shims often use the
      # top-level form (`module GeneratedAttributeMethods; ...; end` outside any class); explicit rooting
      # (`::GeneratedAttributeMethods`) is occasionally seen. Try all three.
      def forms_for_mixin(host_class, mixin_name)
        if mixin_name.start_with?("::")
          [mixin_name, mixin_name.delete_prefix("::")]
        else
          ["#{host_class}::#{mixin_name}", mixin_name, "::#{mixin_name}"]
        end
      end

      def mixin_modules_for(class_name, kind)
        each_class_form(class_name).flat_map { |form| @catalog.mixins_for(form)[kind] }.uniq
      end

      def constant_receiver_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then constant_path_name(node)
        end
      end

      def constant_path_name(node)
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

      # ADR-88 WD2 — resolve the catalog from the `:catalog` producer (disk-cached) and unpack its Marshal-clean
      # bundle into the ivars the return-type / sigil-gate / parse-error paths read. `producer_value` memoises
      # per instance and rescues a producer failure to nil, hence the empty-bundle fallback.
      def ensure_catalog
        return @catalog if @catalog_built

        bundle = producer_value(:catalog) || EMPTY_CATALOG_BUNDLE
        @catalog = bundle[:catalog]
        @sigil_by_path = bundle[:sigil_by_path]
        @parse_errors_by_path = bundle[:parse_errors_by_path]
        @catalog_built = true
        @catalog
      end

      # ADR-88 WD2 — the `watch:` coverage for the `:catalog` producer: the `.rb` sig trees + the `.rbi` trees.
      # An added / removed file under either invalidates the cached bundle even though the block globbed the
      # tree itself. Evaluated at `cache_for` time (after `#init`), so `@configured_paths` / `@rbi_paths` are set.
      def catalog_watch_globs
        [[@configured_paths, "**/*.rb"], [@rbi_paths, "**/*.rbi"]]
      end

      # ADR-88 WD2 — build the Marshal-clean catalog bundle the `:catalog` producer caches. Harvests the `.rb`
      # sig trees then the `.rbi` trees (last-wins ordering preserved from the ivar-mutating original) and
      # returns `{ catalog:, sigil_by_path:, parse_errors_by_path: }`.
      def build_catalog_bundle
        catalog = Catalog.new
        sigil_by_path = {}
        parse_errors_by_path = {}
        # Project source — `.rb` only.
        @configured_paths.each { |root| harvest_path(root, catalog, sigil_by_path, parse_errors_by_path, %w[.rb]) }
        # Sorbet RBI tree — `.rbi` only. Slice 4 of ADR-11.
        @rbi_paths.each { |root| harvest_path(root, catalog, sigil_by_path, parse_errors_by_path, %w[.rbi]) }
        catalog.freeze!
        { catalog: catalog, sigil_by_path: sigil_by_path, parse_errors_by_path: parse_errors_by_path }
      end

      # Frozen empty bundle used when the `:catalog` producer failed (e.g. a project I/O error) so downstream
      # reads see a well-formed shape rather than nil.
      EMPTY_CATALOG_BUNDLE = { catalog: Catalog.new.freeze!, sigil_by_path: {}, parse_errors_by_path: {} }.freeze
      private_constant :EMPTY_CATALOG_BUNDLE

      # @param root [String] directory or single file.
      # @param sigil_by_path [Hash{String=>Symbol}] accumulator: harvested file → detected sigil level.
      # @param parse_errors_by_path [Hash{String=>Array<Hash>}] accumulator: file → `{kind:,line:,column:}` tuples.
      # @param extensions [Array<String>] file extensions to accept (e.g. `[".rb"]` for project source,
      #   `[".rbi"]` for Sorbet RBI tree).
      def harvest_path(root, catalog, sigil_by_path, parse_errors_by_path, extensions)
        absolute = canonicalize(root)
        # ADR-45 WD1b (#613) — boundary-probed: an `sorbet/rbi` tree (or a configured source root) that
        # does not exist yet is a recorded dependency, so creating it invalidates the warm run.
        if io_boundary.directory?(absolute)
          extensions.each do |ext|
            # ADR-88 WD2 — deterministic fold order matters now that the catalog VALUE is digested into the
            # incremental fact-surface fingerprint: a duplicate `(class, method, kind)` sig's last-wins winner
            # must not vary by machine / run. `Dir.glob` sorts its results by default on Ruby 3.0+, so the fold
            # order is already stable (the slice-1 comment's "filesystem order" caveat predates that default);
            # this walk relies on it rather than re-sorting.
            Dir.glob(File.join(absolute, "**", "*#{ext}")).each do |path|
              harvest_file(canonicalize(path), catalog, sigil_by_path, parse_errors_by_path)
            end
          end
        elsif io_boundary.file?(absolute) && extensions.any? { |ext| absolute.end_with?(ext) }
          # `paths:` may list individual files (the demos do this); walk them directly rather than skipping.
          harvest_file(absolute, catalog, sigil_by_path, parse_errors_by_path)
        end
      end

      # Canonicalises a path through `File.realpath` so it matches the form `Plugin::TrustPolicy#allow_read?`
      # sees (the runner builds the policy's roots from `Dir.pwd`, which has symlinks resolved on macOS —
      # `/tmp` → `/private/tmp` etc.). Falls back to `File.expand_path` when realpath fails (e.g. the path
      # no longer exists).
      def canonicalize(path)
        expanded = File.expand_path(path)
        File.exist?(expanded) ? File.realpath(expanded) : expanded
      rescue StandardError
        expanded
      end

      def harvest_file(path, catalog, sigil_by_path, parse_errors_by_path)
        contents = io_boundary.read_file(path)
        return if contents.nil?

        # ADR-11 slice 5 — honour Sorbet's `# typed: ignore` magic comment by skipping the file entirely.
        level = SigilDetector.detect(contents)
        # Per-call-site assertion gating consults this map at recognition time. Recorded BEFORE the
        # ignored short-circuit so a `# typed: ignore` file still reports its level to the gate (the gate
        # then chooses to suppress assertions there too — `ignore` is stricter than `false`).
        sigil_by_path[path] = level
        return if SigilDetector.ignored?(level)

        result = Prism.parse(contents)
        return unless result.errors.empty?

        # `enforce_sigil` follow-up — when on (default), files at `:false` (or sigil-less, which Sorbet
        # treats as `:false`) are STILL walked so parse-error diagnostics surface, but sigs flow into a
        # discardable catalog rather than the per-run one. Sorbet itself doesn't enforce types at `#
        # typed: false`, and Rigor mirrors that for sig contributions. Assertion recognisers (`T.let` /
        # `T.cast` / `T.must` / `T.bind` / `T.assert_type!`) stay live regardless of sigil — the user
        # wrote those deliberately.
        sig_catalog = if @enforce_sigil && !SigilDetector.enforced?(level)
                        Catalog.new
                      else
                        catalog
                      end

        errors = CatalogWalker.walk(root: result.value, catalog: sig_catalog, path: path)
        # ADR-88 WD2 — store Marshal-clean `{kind:, line:, column:}` tuples, not the `ParseError` (it holds a
        # live Prism node the producer bundle could not serialise). `diagnostics_for_file` rebuilds the
        # diagnostic from the tuple, at the same 1-based line / `start_column + 1` position `from_node` gave.
        parse_errors_by_path[path] = errors.map { |error| parse_error_tuple(error) } unless errors.empty?
      rescue Plugin::AccessDeniedError, Errno::ENOENT
        # Skip files outside the trusted read scope or that vanished between glob and read; the plugin
        # produces no output for them.
        nil
      end

      # ADR-88 WD2 — the Marshal-clean position tuple for a `CatalogWalker::ParseError`, capturing the node's
      # location at harvest time so the producer bundle carries no live Prism node.
      def parse_error_tuple(error)
        location = error.node.location
        { kind: error.kind, line: location.start_line, column: location.start_column + 1 }
      end

      # Emits a `plugin.sorbet.absurd-reachable` warning for the `T.absurd(x)` call recorded in
      # `@reachable_absurd_nodes` during inference; the node rule above does the identity match and pop.
      def absurd_diagnostic(path, call_node)
        Rigor::Analysis::Diagnostic.from_node(
          call_node,
          path: path,
          message: "`T.absurd` is reachable: the discriminant did not narrow to `T.noreturn`. " \
                   "Either add the missing case branch above the `else`, or remove the " \
                   "`T.absurd(...)` call.",
          severity: :warning,
          rule: "absurd-reachable"
        )
      end

      # ADR-11 light follow-up — `T.reveal_type(expr)` records the inferred type at recogniser time so the
      # per-file diagnostic hook can surface the human-facing message. The reveal call's contribution
      # already preserved the inferred type for downstream chaining; this hash carries the *display*
      # string that the diagnostic shows.
      def record_reveal_type_call(call_node, return_type)
        @reveal_type_calls[call_node] = display_for_type(return_type)
      end

      def display_for_type(type)
        # `Type#describe` is the human-facing display contract used by `rigor type-of`'s text renderer.
        return "untyped" if type.nil?

        type.respond_to?(:describe) ? type.describe : type.inspect
      end

      def reveal_type_diagnostic(path, call_node, display)
        Rigor::Analysis::Diagnostic.from_node(
          call_node,
          path: path,
          message: "`T.reveal_type` inferred type: #{display}",
          severity: :info,
          rule: "reveal-type"
        )
      end

      # T.bind / T.assert_type! priority slice 1 — runs the static subtype check at recogniser time and
      # records the call only when the inferred type is *provably incompatible* with the asserted type.
      # Gradual consistency rules (`Type#accepts` mode `:gradual`): a `Dynamic[top]` inferred type
      # silences the check; a definite `:no` records for diagnostic emission; `:maybe` (uncertain) is
      # treated as "trust the user" and silenced — the runtime check is there for those cases.
      def record_assert_type_check(call_node, scope)
        check = AssertionRecognizer.assert_type_check(call_node, scope)
        return if check.nil?

        inferred, asserted = check
        return if inferred.nil?

        result = asserted.accepts(inferred)
        return unless result.no?

        @assert_type_mismatches[call_node] = [display_for_type(inferred), display_for_type(asserted)]
      end

      def assert_type_mismatch_diagnostic(path, call_node, inferred_display, asserted_display)
        Rigor::Analysis::Diagnostic.from_node(
          call_node,
          path: path,
          message: "`T.assert_type!` failed: inferred type #{inferred_display} is not " \
                   "compatible with asserted type #{asserted_display}.",
          severity: :error,
          rule: "assert-type-mismatch"
        )
      end

      # ADR-88 WD2 — `error` is a Marshal-clean `{kind:, line:, column:}` tuple (the pre-computed node
      # location), not a Prism-node-bearing `ParseError`; build the diagnostic directly at that position (the
      # `line` / `column` `from_node` would have derived).
      def parse_error_diagnostic(path, error)
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: error[:line],
          column: error[:column],
          message: parse_error_message(error[:kind]),
          severity: :warning,
          rule: "parse-error"
        )
      end

      def parse_error_message(kind)
        case kind
        when :no_block then "Sorbet `sig` call missing a block."
        when :empty_block then "Sorbet `sig` block is empty."
        when :missing_returns_or_void
          "Sorbet `sig` block must end in `.returns(...)` or `.void`."
        when :duplicate_sig
          "Two `sig` blocks in a row; the first one has no following method definition."
        when :dangling_sig
          "`sig` block is not immediately followed by a method definition."
        else "Sorbet `sig` block did not parse (#{kind})."
        end
      end
    end

    Rigor::Plugin.register(Sorbet)
  end
end
