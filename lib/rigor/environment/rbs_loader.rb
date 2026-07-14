# frozen_string_literal: true

require "rbs"

require_relative "../type"
require_relative "../inference/rbs_type_translator"
require_relative "rbs_hierarchy"

module Rigor
  class Environment
    # Loads RBS class declarations and method definitions from disk and exposes them to the inference engine
    # in a small, stable surface.
    #
    # Slice 4 phase 1 only enabled the RBS *core* signatures shipped with the `rbs` gem (`Object`, `Integer`,
    # `String`, `Array`, ...). Phase 2a adds opt-in stdlib library loading (`pathname`, `json`, `tempfile`,
    # ...) and arbitrary-directory signature loading (typically the project's local `sig/` tree). Both are
    # off by default on `RbsLoader.default` so the core-only fast path stays cheap; project-aware loading is
    # opted into through {Environment.for_project} or by constructing a custom loader.
    #
    # The default instance is shared across the process: building the core RBS environment costs hundreds of
    # milliseconds and the data is read-only. The shared instance is frozen, but holds a mutable state hash
    # for lazy memoization of the heavy `RBS::Environment` and `RBS::DefinitionBuilder` -- the user-visible
    # API stays purely functional.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract.
    # rubocop:disable Metrics/ClassLength
    class RbsLoader
      # Buffer name stamped on the `module` declarations synthesized by {.synthesize_missing_namespaces}.
      # Re-read off the built env by {#synthesized_namespaces} so the analysis layer can surface an `:info`
      # diagnostic naming the project's malformed-RBS namespaces — robust across the marshalled env cache,
      # since the sentinel rides along on each synthetic declaration's location.
      SYNTHETIC_NAMESPACE_BUFFER = "(rigor: synthesized namespaces)"

      # Buffer name stamped on the stub `class` / `module` declarations synthesized by
      # {.stub_missing_referenced_types} for types the project's RBS references but no loaded signature
      # declares. {#synthesized_stub_types} reads them back off the built env (so the answer survives the
      # marshalled env cache), and {#synthesized_type_names} folds them together with the namespace stubs
      # into the set {MethodDispatcher} resolves to `Dynamic[Top]` (no false `call.undefined-method`).
      SYNTHETIC_STUB_BUFFER = "(rigor: synthesized stub types)"

      # Cap on how many quarantined `signature_paths:` files {#warn_about_quarantined_signatures} lists by name
      # before collapsing the tail to "… and N more" — a broken generator can emit many, and a wall of parse
      # errors buries the signal.
      QUARANTINE_WARN_LIMIT = 10

      class << self
        def default
          @default ||= new.freeze
        end

        # Used by tests to discard the cached default loader; production code MUST NOT call this. The shared
        # loader holds a several-MB RBS::Environment, so dropping it during a normal run wastes the cost of
        # rebuilding it.
        def reset_default!
          @default = nil
        end

        # Builds an `RBS::Environment` from explicit `libraries` and `signature_paths`. Stateless surface so
        # the v0.0.9 {Cache::RbsEnvironment} producer can build an env on cache miss without holding a loader
        # instance, and the instance-side {#build_env} delegates here so the implementation stays
        # single-rooted.
        #
        # Vendored gem stubs (`data/vendored_gem_sigs/<gem>/`) are loaded on top of `signature_paths` so the
        # per-gem RBS bundled with Rigor itself is in scope for every analysis run. The gem stubs are
        # intentionally read-only and appended LAST so user-supplied `signature_paths` win on name conflicts.
        def build_env_for(libraries:, signature_paths:, virtual_rbs: [])
          rbs_loader = RBS::EnvironmentLoader.new
          libraries.each do |library|
            next unless rbs_loader.has_library?(library: library, version: nil)

            rbs_loader.add(library: library, version: nil)
          end
          # Project `signature_paths:` are loaded per-file by {.add_project_signatures} AFTER `from_loader`,
          # NOT added to the loader here: `RBS::Environment.from_loader` parses every added file all-or-nothing,
          # so one unparseable user `.rbs` raises `RBS::ParsingError` and collapses the WHOLE env to nil (every
          # type-of query then degrades to `Dynamic[top]` — the "sig looks harmful" failure of the 2026-07-06
          # mastodon coverage note). Per-file loading quarantines the broken file instead. Vendored / core-overlay
          # sigs are Rigor-shipped and trusted, so they stay on the loader's fast batch path.
          vendored_gem_sig_paths.each do |path|
            rbs_loader.add(path: path) if path.directory?
          end
          # Rigor-owned core overlay — loaded LAST so an upstream declaration always wins on conflict; these
          # reopenings only fill genuine holes (e.g. `Numeric#to_f`/`to_i`/`to_r`, which upstream RBS
          # declares on the concrete subclasses but not on the abstract `Numeric` that Rigor's
          # arithmetic-chain widening produces).
          core_overlay_sig_paths.each do |path|
            rbs_loader.add(path: path) if path.directory?
          end
          env = RBS::Environment.from_loader(rbs_loader)
          add_project_signatures(env, signature_paths)
          add_virtual_rbs(env, virtual_rbs)
          synthesize_missing_namespaces(env)
          resolved = env.resolve_type_names
          stub_missing_referenced_types(env, resolved, project_sig_files(signature_paths))
        end

        # ADR-5 robustness, second tier. A project `signature_paths:` RBS that *references* a type no loaded
        # signature declares — `def x: () -> DRb::DRbServer` when the `drb` RBS is not available, or a stale
        # reference to its own removed `Textbringer::EditorError` — makes
        # `RBS::DefinitionBuilder#build_instance` raise `NoTypeFoundError`, and (per RBS's all-or-nothing
        # per-class build) that single unresolved reference takes down EVERY method on the class, not just
        # the one signature. Observed on shugo/textbringer: one `DRb::DRbServer` reference left the whole
        # `Textbringer::Commands` module — including its 186-call-site `define_command` DSL — resolving as
        # `Dynamic[Top]`.
        #
        # We synthesize an empty stub for each such referenced-but- undeclared type so the rest of the class
        # builds. A leaf type is stubbed as `class`, its enclosing namespaces as `module`. Stubbed types
        # carry no methods, so a call against a value of a stubbed type would otherwise mis-fire
        # `call.undefined-method`; {MethodDispatcher} consults {#synthesized_type_names} and resolves such
        # calls to `Dynamic[Top]` instead (the same no-false-positive contract as the dependency-source
        # tier).
        #
        # Detection re-uses RBS's own builder (correct by construction): build every PROJECT class and read
        # the missing name out of the raised error. Bounded to `signature_paths` classes (stdlib / vendored
        # RBS is well-formed) and to {MAX_STUB_PASSES} iterations — a fresh stub can expose a deeper
        # reference the first build error hid, but empty stubs reference nothing, so the fixpoint converges
        # quickly.
        MAX_STUB_PASSES = 5

        def stub_missing_referenced_types(base_env, resolved, project_files)
          return resolved if project_files.empty?

          MAX_STUB_PASSES.times do
            missing = unresolved_referenced_types(resolved, project_files)
            break if missing.empty?

            append_stub_declarations(base_env, missing)
            resolved = base_env.resolve_type_names
          end
          resolved
        end

        # Robustness (ADR-5): a project whose RBS declares qualified names (`class Foo::Bar`) without ever
        # declaring the enclosing namespace (`module Foo`) is invalid by upstream RBS rules —
        # `RBS::DefinitionBuilder#build_instance` raises `NoTypeFoundError: Could not find ::Foo`, which the
        # loader's fail-soft rescue turns into a silent dispatch miss (every method on every such class
        # degrades to `Dynamic[Top]`). This is a common authoring mistake (e.g. shugo/textbringer ships a
        # `sig/` that `rbs validate` itself rejects). Rather than let an otherwise-usable signature set
        # contribute nothing, synthesize an empty `module` declaration for each undeclared enclosing
        # namespace so the definitions build. We only ever add names that are absent — a genuinely-declared
        # namespace (module or class, here or in a loaded gem) is left untouched.
        def synthesize_missing_namespaces(env)
          missing = collect_missing_namespaces(env)
          return if missing.empty?

          source = missing.map { |name| "module #{name}\nend\n" }.join
          buffer = ::RBS::Buffer.new(name: SYNTHETIC_NAMESPACE_BUFFER, content: source)
          _, directives, decls = ::RBS::Parser.parse_signature(buffer)
          add_parsed_decls(env, buffer, directives, decls)
        rescue ::RBS::BaseError
          # Fail-soft: synthesis is an opportunistic uplift, never a hard requirement. A parse failure here
          # just leaves the env as it was (dispatch misses on the affected classes).
          nil
        end

        # Returns the `::`-stripped names of every enclosing namespace that some declaration references but
        # no declaration defines, shallowest-first so the synthesized source declares `Foo` before
        # `Foo::Bar`.
        def collect_missing_namespaces(env)
          declared = env.class_decls.keys.to_set
          missing = {}
          env.class_decls.each_key do |type_name|
            path = type_name.namespace.path
            path.each_index do |i|
              prefix = path[0..i]
              full = ::RBS::TypeName.parse("::#{prefix.join('::')}")
              missing[prefix.join("::")] = prefix.length unless declared.include?(full)
            end
          end
          missing.sort_by { |_name, depth| depth }.map(&:first)
        end

        # The absolute paths of every `.rbs` file under the project's `signature_paths:` (NOT vendored /
        # stdlib RBS — those are well-formed, so attempting to build them would only waste time). Used to
        # scope the referenced-type build sweep.
        def project_sig_files(signature_paths)
          signature_paths.flat_map do |path|
            path = Pathname(path) unless path.is_a?(Pathname)
            next [] unless path.directory?

            Dir.glob(path.join("**", "*.rbs")).map { |p| File.expand_path(p) }
          end.to_set
        end

        # Load the project's `signature_paths:` RBS files into `env` ONE FILE AT A TIME, quarantining any file
        # that fails to parse rather than letting it collapse the whole env (the `from_loader` batch parse is
        # all-or-nothing — see {.build_env_for}). A quarantined file's declarations are simply absent, so calls
        # into the types it would have declared read `Dynamic[top]`; the rest of the project's (and all
        # bundled) RBS still loads. The user is told which files were skipped via
        # {RbsLoader#warn_about_quarantined_signatures}, so this is a graceful degrade, not a silent one.
        #
        # Buffer names are the file's absolute path (matching {.project_sig_files}) so {.project_entry?} — which
        # attributes a `class_decls` entry to the project by buffer name — still recognises these declarations.
        # Sorted for a deterministic add order (the env feeds the cache, ADR-54).
        def add_project_signatures(env, signature_paths)
          project_sig_files(signature_paths).sort.each do |file|
            parsed = parse_signature_file(file)
            next if parsed.nil? # quarantined (unparseable) or unreadable — skip so the env survives

            buffer, directives, decls = parsed
            add_parsed_decls(env, buffer, directives, decls)
          end
        end

        # Parse one project `.rbs` into `[buffer, directives, decls]`, or nil when it is unparseable /
        # unreadable. Mirrors `RBS::EnvironmentLoader#each_signature`'s per-file parse so the decls register
        # identically to the loader's batch path.
        def parse_signature_file(file)
          buffer = ::RBS::Buffer.new(name: file, content: File.read(file, encoding: "UTF-8"))
          _buffer, directives, decls = ::RBS::Parser.parse_signature(buffer)
          [buffer, directives, decls]
        rescue ::RBS::ParsingError, Errno::ENOENT, Errno::EISDIR, Errno::EACCES
          nil
        end

        # The project `signature_paths:` files that FAIL to parse, as `[absolute_path, first_error_line]` pairs
        # (sorted, deterministic). Detection is independent of {.add_project_signatures} so the warning fires
        # even on a cache hit (where the env was already built with the file quarantined). Cheap: it only
        # re-parses the user's own (usually small) `sig/` set, and returns empty immediately when there is no
        # `signature_paths:`.
        def quarantined_project_signatures(signature_paths)
          project_sig_files(signature_paths).sort.filter_map do |file|
            buffer = ::RBS::Buffer.new(name: file, content: File.read(file, encoding: "UTF-8"))
            ::RBS::Parser.parse_signature(buffer)
            nil
          rescue ::RBS::ParsingError => e
            [file, e.message.to_s.lines.first.to_s.strip]
          rescue Errno::ENOENT, Errno::EISDIR, Errno::EACCES
            nil
          end
        end

        # Builds every project class (instance + singleton side) and returns the `::`-stripped names of the
        # types whose absence raised `NoTypeFoundError`. Only the FIRST missing reference per class surfaces
        # per build, which is why the caller loops.
        def unresolved_referenced_types(env, project_files)
          builder = ::RBS::DefinitionBuilder.new(env: env)
          missing = []
          env.class_decls.each do |type_name, entry|
            next unless project_entry?(entry, project_files)

            %i[build_instance build_singleton].each do |build|
              builder.public_send(build, type_name)
            rescue ::RBS::NoTypeFoundError => e
              name = e.message[/Could not find (\S+)/, 1]
              missing << name.sub(/\A::/, "") if name
            rescue ::RBS::BaseError
              # Other build failures (duplicate decl, mixin cycle, ...) are not ours to repair here — leave
              # them fail-soft.
            end
          end
          missing.uniq
        end

        # Normalises a `class_decls` entry's representative declaration across the gemspec's supported RBS
        # range (`rbs >= 3.0, < 5.0`). RBS 4.x exposes it as `entry.primary_decl` (the AST declaration
        # directly); RBS 3.x exposes `entry.primary` (a wrapper whose `#decl` is the AST declaration).
        # Returns the AST declaration, or nil when neither accessor is present. Without this guard,
        # `class_decl_paths` crashed under RBS 3.x with `undefined method 'primary_decl'`.
        def primary_decl_for(entry)
          if entry.respond_to?(:primary_decl)
            entry.primary_decl
          elsif entry.respond_to?(:primary)
            primary = entry.primary
            primary.respond_to?(:decl) ? primary.decl : primary
          end
        end

        # Appends freshly-parsed declarations to an `RBS::Environment` across the gemspec's supported RBS
        # range (`rbs >= 3.0, < 5.0`). RBS 4.x wraps the declarations in an `RBS::Source::RBS` and takes them
        # through `env.add_source`; RBS 3.x has neither `RBS::Source` nor `add_source` and instead registers
        # them with `env.add_signature(buffer:, directives:, decls:)` (a bare `env << decl` is NOT enough —
        # it skips the `signatures` table that `resolve_type_names` rebuilds from, so the synthesized
        # declarations silently vanish on resolve). Without this guard the synthesis paths
        # (`synthesize_missing_namespaces`, `append_stub_declarations`, `add_virtual_rbs`) crashed under RBS
        # 3.x with `uninitialized constant RBS::Source`.
        def add_parsed_decls(env, buffer, directives, decls)
          decls ||= []
          directives ||= []
          if env.respond_to?(:add_source)
            env.add_source(::RBS::Source::RBS.new(buffer, directives, decls))
          elsif env.respond_to?(:add_signature)
            env.add_signature(buffer: buffer, directives: directives, decls: decls)
          else
            decls.each { |decl| env << decl }
          end
        end

        # True when a `class_decls` entry was declared in one of the project's own signature files (by
        # declaration location), so the sweep skips the bundled stdlib / vendored universe.
        def project_entry?(entry, project_files)
          decl = primary_decl_for(entry)
          location = decl&.location
          buffer_name = location&.buffer&.name
          return false unless buffer_name

          project_files.include?(File.expand_path(buffer_name.to_s))
        end

        # Adds empty stub declarations for the missing referenced types (and any enclosing namespace they
        # need) to the pre-resolve env, tagged with {SYNTHETIC_STUB_BUFFER}. A name that is a prefix of
        # another name is declared `module` (it is a namespace); a leaf is declared `class` (referenced types
        # appear in instance position far more often than as mixins).
        #
        # Names already declared in `base_env` are skipped — exactly the `declared.include?` guard
        # {.collect_missing_namespaces} applies. Without it, stubbing a nested reference (`Foo::Bar::Baz`)
        # re-emits its enclosing prefix (`Foo::Bar`) as a `module`, and when that prefix is already a `class`
        # in the project's own `sig/` the kind mismatch makes `resolve_type_names` raise
        # `RBS::DuplicatedDeclarationError`, collapsing the WHOLE env to nil (every type-of query then
        # degrades to `Dynamic[Top]`). One malformed `.rbs` must not disproportionately blind the analysis: a
        # subclass sig that references an inherited nested type (`class GitAdapter; def x: () ->
        # GitAdapter::Revision`) was the real-world trigger — see the 2026-07-04 redmine onboarding note.
        def append_stub_declarations(base_env, missing)
          declared = declared_type_names(base_env)
          names = missing.to_set
          missing.each do |name|
            parts = name.split("::")
            (1...parts.length).each { |i| names << parts[0, i].join("::") }
          end
          names = names.reject { |name| declared.include?(name) }.to_set
          return if names.empty?

          source = names.sort_by { |n| n.count(":") }.map do |name|
            keyword = names.any? { |other| other != name && other.start_with?("#{name}::") } ? "module" : "class"
            "#{keyword} #{name}\nend\n"
          end.join
          buffer = ::RBS::Buffer.new(name: SYNTHETIC_STUB_BUFFER, content: source)
          _, directives, decls = ::RBS::Parser.parse_signature(buffer)
          add_parsed_decls(base_env, buffer, directives, decls)
        rescue ::RBS::BaseError
          nil
        end

        # The `::`-stripped names of every class / module / class-alias declaration already present in
        # `env`, so the synthesis paths never re-declare (and thereby duplicate) a real declaration.
        def declared_type_names(env)
          names = env.class_decls.keys.map { |n| n.to_s.sub(/\A::/, "") }
          if env.respond_to?(:class_alias_decls)
            names.concat(env.class_alias_decls.keys.map { |n| n.to_s.sub(/\A::/, "") })
          end
          names.to_set
        end

        # ADR-32 WD4 — merge synthesised-from-source RBS strings into the freshly-built environment. Each
        # entry is a `[virtual_filename, rbs_source]` pair. `virtual_filename` is purely for diagnostic
        # provenance (RBS parse errors cite it) — it is not a real file path. Per WD6 the synthesizer-emit
        # path is responsible for catching its own parse errors and returning `nil` rather than garbage; this
        # method assumes its input is parseable and only rescues `RBS::ParsingError` as a fail-soft.
        def add_virtual_rbs(env, virtual_rbs)
          return if virtual_rbs.nil? || virtual_rbs.empty?

          virtual_rbs.each do |filename, content|
            next if content.nil? || content.empty?

            buffer = ::RBS::Buffer.new(name: filename.to_s, content: content.to_s)
            _, directives, decls = ::RBS::Parser.parse_signature(buffer)
            add_parsed_decls(env, buffer, directives, decls)
          rescue ::RBS::BaseError
            # WD6 fail-soft: a single broken virtual RBS contribution does not pull the whole env down. The
            # plugin layer records a `source-rbs-synthesis-failed` info diagnostic in slice 2; here we just
            # skip the entry.
          end
        end

        # Per-gem `data/vendored_gem_sigs/<gem>/` directories that ship with Rigor. Each subdirectory is one
        # gem's RBS surface (the `<gem>.rbs` file is the typical content; `LICENSE.upstream` records
        # provenance). Coverage is deliberately scoped to the native-extension and "everywhere in Rails" gems
        # whose absence dominated `call.undefined-method` noise in the real-world survey at
        # `docs/notes/20260515-real-world-rails-survey.md`.
        VENDORED_GEM_SIGS_ROOT = File.expand_path(
          "../../../data/vendored_gem_sigs",
          __dir__
        ).freeze
        private_constant :VENDORED_GEM_SIGS_ROOT

        # Rigor-owned core-overlay RBS (`data/core_overlay/`). Reopens Ruby core classes to add methods
        # upstream `ruby/rbs` omits but which every concrete value answers at runtime — loaded last so
        # upstream always wins on conflict. Public so the cache descriptor can digest these files into the
        # env-blob key.
        CORE_OVERLAY_SIGS_ROOT = File.expand_path(
          "../../../data/core_overlay",
          __dir__
        ).freeze

        def core_overlay_sig_paths
          return [] unless File.directory?(CORE_OVERLAY_SIGS_ROOT)

          [Pathname(CORE_OVERLAY_SIGS_ROOT)]
        end

        # Rigor-owned per-gem RBS overlays (`data/gem_overlay/<gem>/`), ADR-72. Unlike the unconditional
        # `core_overlay`, each gem's overlay is loaded ONLY when that gem is locked in the project's
        # Gemfile.lock but ships no RBS of its own — {Environment.for_project} decides eligibility and passes
        # the already-filtered gem-name set here. One directory per gem name keeps the membership check a
        # cheap `File.directory?`.
        GEM_OVERLAY_SIGS_ROOT = File.expand_path(
          "../../../data/gem_overlay",
          __dir__
        ).freeze

        # @param gem_names [Enumerable<String>] overlay-eligible Gemfile.lock gem names (the caller filters
        #   to the `:missing`-coverage, no-conflicting-plugin set).
        # @return [Array<Pathname>] the bundled overlay directory for each gem that ships one; empty when
        #   none match or the overlay root is absent.
        def gem_overlay_sig_paths(gem_names)
          return [] unless File.directory?(GEM_OVERLAY_SIGS_ROOT)

          gem_names.filter_map do |name|
            dir = File.join(GEM_OVERLAY_SIGS_ROOT, name.to_s)
            Pathname(dir) if File.directory?(dir)
          end
        end

        def vendored_gem_sig_paths
          return [] unless File.directory?(VENDORED_GEM_SIGS_ROOT)

          Dir.children(VENDORED_GEM_SIGS_ROOT).map do |gem_dir|
            Pathname(File.join(VENDORED_GEM_SIGS_ROOT, gem_dir))
          end
        end

        # Gem names whose RBS ships under `data/vendored_gem_sigs/<gem>/`. The directory walk is the source
        # of truth (the `README.md` sibling is not a gem and is excluded). Callers building the RBS env use
        # this set to drop the matching `rbs collection install` directory before it double-declares against
        # the vendored copy — the same hazard `DEFAULT_LIBRARIES` creates for stdlib-extracted gems. See
        # `RbsCollectionDiscovery`'s `skip_gem_names:`.
        def vendored_gem_names
          return [] unless File.directory?(VENDORED_GEM_SIGS_ROOT)

          Dir.children(VENDORED_GEM_SIGS_ROOT).reject do |child|
            File.file?(File.join(VENDORED_GEM_SIGS_ROOT, child))
          end
        end
      end

      attr_reader :libraries, :signature_paths, :cache_store, :virtual_rbs

      # @param libraries [Array<String, Symbol>] stdlib library names to load on top of core (e.g.,
      #   `["pathname", "json"]`). Empty by default. Each entry MUST correspond to a directory under the
      #   `rbs` gem's `stdlib/` tree; unknown names are silently dropped on environment build (the underlying
      #   `RBS::EnvironmentLoader` raises and we fail-soft).
      # @param signature_paths [Array<String, Pathname>] additional directories of `.rbs` files to load
      #   (typically the project's `sig/` tree). Non-existent or non-directory paths are filtered out at
      #   build time so the loader stays robust to fixtures and bare repositories.
      # @param cache_store [Rigor::Cache::Store, nil] the persistent cache the loader threads through to
      #   `RbsEnvironment`, `RbsKnownClassNames`, `RbsConstantTable`, `RbsClassAncestorTable`, and
      #   `RbsClassTypeParamNames` producers. Pass `nil` (the default) to skip caching; the runner threads
      #   its own Store through here when enabled.
      # @param virtual_rbs [Array<[String, String]>] ADR-32 WD4 — `[virtual_filename, rbs_source]` pairs
      #   synthesised from project source by a plugin's `Manifest#source_rbs_synthesizer`. Merged into the
      #   env after `signature_paths:` and the vendored stubs. Pass `[]` (the default) when no
      #   synthesizer-emitting plugin is loaded.
      def initialize(libraries: [], signature_paths: [], cache_store: nil, virtual_rbs: [])
        @libraries = libraries.map(&:to_s).freeze
        @signature_paths = signature_paths.map { |p| Pathname(p) }.freeze
        @cache_store = cache_store
        @virtual_rbs = virtual_rbs.map { |name, content| [name.to_s.dup.freeze, content.to_s.dup.freeze].freeze }.freeze
        # Per-loader memoization bucket. Held as a single mutable Hash so the loader instance itself can be
        # `.freeze`d (per ADR-15 reflection-facade contract) without losing the lazy-memo behaviour. Slot
        # names currently consulted: `:env`, `:env_loaded`, `:env_build_warned`, `:builder`, `:reflection`,
        # `:instance_definitions_table`, `:singleton_definitions_table`. Constructed via `Hash.new` (NOT a
        # `{ ... }` literal) so Rigor's `HashShape` narrowing doesn't infer a fixed key set from the initial
        # state and fold post-initial slot reads (e.g. `@state[:env_loaded]`) to a constant `nil`.
        @state = Hash.new # rubocop:disable Style/EmptyLiteral
        @instance_definition_cache = {}
        @singleton_definition_cache = {}
        @class_known_cache = {}
        @hierarchy = RbsHierarchy.new(self)
      end

      # The enclosing namespaces {.synthesize_missing_namespaces} had to invent because the project's
      # `signature_paths:` RBS declared qualified names (`class Foo::Bar`) without ever declaring `Foo`.
      # Recovered by scanning the built env for class/module entries whose every declaration originated from
      # the synthetic buffer, so the answer survives the marshalled-env cache (where no build-time collector
      # would). Returns `::`-stripped names, shallowest-first. Empty for a well-formed sig set (the common
      # case) and whenever the env failed to build.
      def synthesized_namespaces
        names_synthesized_in(SYNTHETIC_NAMESPACE_BUFFER)
      end

      # The project `signature_paths:` files that were QUARANTINED this run (they do not parse, so
      # {RbsLoader.add_project_signatures} skipped them to keep the rest of the env alive), as
      # `[absolute_path, first_error_line]` pairs. Memoised per loader: the detection re-parses only the user's
      # own `sig/` set, but every consumer (the `rbs.coverage.quarantined-signature` diagnostic, `rigor doctor`,
      # the stderr banner) reads it, and a cache HIT reaches it too — the env was built with the file already
      # quarantined, so the condition is invisible in the cached env itself.
      #
      # @return [Array<Array(String, String)>] empty when every `signature_paths:` file parses.
      def quarantined_signatures
        @state[:quarantined] ||= self.class.quarantined_project_signatures(@signature_paths).freeze
      end

      # The referenced-but-undeclared types {.stub_missing_referenced_types} stubbed so the project classes
      # that mention them could build (e.g. an unavailable `DRb::DRbServer`, or a stale
      # `Textbringer::EditorError`). Recovered off the built env like {#synthesized_namespaces}, so it
      # survives the marshalled-env cache.
      def synthesized_stub_types
        names_synthesized_in(SYNTHETIC_STUB_BUFFER)
      end

      # Every type name Rigor invented to make an otherwise-inert / unbuildable project signature set resolve
      # — both the namespace stubs and the referenced-type stubs. {MethodDispatcher} resolves a call whose
      # receiver is one of these (and that no real signature answered) to `Dynamic[Top]`, so the empty stub
      # never mis-fires `call.undefined-method`. Memoised; empty (and cheap) for the common well-formed sig
      # set.
      def synthesized_type_names
        @state[:synthesized_type_names] ||= (synthesized_namespaces + synthesized_stub_types).to_set
      end

      # Returns true when an RBS class or module declaration with the given name is loaded. Accepts
      # unprefixed or top-level-prefixed names ("Integer" or "::Integer"). Memoized per-name (positive and
      # negative results both cache).
      #
      # When `cache_store` is set, the loader fetches the entire set of known class / module / alias names
      # once (per process) through {Cache::RbsKnownClassNames.fetch} and answers `class_known?` from the
      # in-memory Set. Cold runs pay a single env walk and persist the result; warm runs (and a separate
      # loader sharing the same Store) skip the env walk entirely.
      def class_known?(name)
        key = name.to_s
        return @class_known_cache[key] if @class_known_cache.key?(key)

        @class_known_cache[key] = if cache_store
                                    cached_class_known(name)
                                  else
                                    compute_class_known(name)
                                  end
      end

      # Returns true when the named RBS declaration is a Module (`RBS::AST::Declarations::Module`) rather
      # than a Class. The `user_class_fallback_receiver` tier consults this to route
      # `Nominal[M].some_kernel_method` (where M is a module mixin like `PP::ObjectMixin`) through the
      # `Nominal[Object]` fallback, because every concrete includer of M sees Kernel / Object instance
      # methods as part of its own ancestor chain.
      #
      # Returns false for classes, for unknown names, and when the RBS environment failed to build
      # (fail-soft).
      def rbs_module?(name)
        return false if env.nil?

        rbs_name = parse_type_name(name)
        return false if rbs_name.nil?

        entry = env.class_decls[rbs_name]
        entry.is_a?(::RBS::Environment::ModuleEntry)
      rescue ::RBS::BaseError
        false
      end

      # Yields every known class / module / alias name (top-level prefixed) currently loaded into the
      # environment. The cache producer that materialises the known-name set uses this so it never recurses
      # back through {#class_known?}.
      def each_known_class_name
        return enum_for(:each_known_class_name) unless block_given?
        return if env.nil?

        env.class_decls.each_key { |rbs_name| yield rbs_name.to_s }
        env.class_alias_decls.each_key { |rbs_name| yield rbs_name.to_s }
      rescue ::RBS::BaseError
        # fail-soft: a broken RBS environment yields no names. Analyzer-internal errors (NameError,
        # NoMethodError, LoadError) are NOT swallowed — those are bugs and must surface so they don't hide
        # silently the way the v0.0.9 cache `Cache::Descriptor` regression did.
      end

      # ADR-20 slice 2e — iterates over every `%a{...}` annotation attached to a class- or module-level
      # declaration in the loaded RBS environment, yielding `(annotation_string, source_location)` pairs.
      # Used by {Rigor::Inference::HktRegistry.scan_rbs_loader} to find `rigor:v1:hkt_register` /
      # `rigor:v1:hkt_define` directives in user-authored overlays and merge them into the per-`Environment`
      # HKT registry. Yields nothing when the env failed to build (fail-soft, same shape as
      # {#each_known_class_name}).
      def each_class_decl_annotation
        return enum_for(:each_class_decl_annotation) unless block_given?
        return if env.nil?

        env.class_decls.each_value do |entry|
          entry.each_decl do |decl|
            next unless decl.respond_to?(:annotations)

            decl.annotations.each { |a| yield a.string, a.location }
          end
        end
      rescue ::RBS::BaseError, ::Ractor::IsolationError
        # fail-soft: matches each_known_class_name's policy. Ractor::IsolationError surfaces when the scan
        # is invoked from a non-main Ractor pool worker before ADR-15's full deep-freeze migration completes
        # — the worker falls back to the base (builtins-only) registry rather than crashing.
      end

      # Like {#each_class_decl_annotation}, but also yields the owning class / module's RBS name as the
      # first block argument: `(class_name, annotation_string, location)`. Used by
      # {Rigor::RbsExtended::ConformanceChecker} to resolve a `rigor:v1:conforms-to` directive back to the
      # class it annotates. Same fail-soft policy as the un-named variant.
      def each_class_decl_annotation_with_name
        return enum_for(:each_class_decl_annotation_with_name) unless block_given?
        return if env.nil?

        env.class_decls.each do |rbs_name, entry|
          entry.each_decl do |decl|
            next unless decl.respond_to?(:annotations)

            decl.annotations.each { |a| yield rbs_name.to_s, a.string, a.location }
          end
        end
      rescue ::RBS::BaseError, ::Ractor::IsolationError
        # fail-soft: see #each_class_decl_annotation.
      end

      # Returns a frozen `Hash<String, String>` mapping each loaded class / module name (top-level prefixed)
      # to the file path of its FIRST declaration's RBS source. Used by {Rigor::Analysis::RunStats} to
      # attribute the type universe between "project sig/" (paths under the configured `signature_paths`)
      # and "bundled" (everything else — RBS core, stdlib libraries, gem-bundled RBS). Each value is a frozen
      # `String` so the whole result is `Ractor.shareable?` — the Phase 4b worker pool ships a snapshot back
      # to the coordinator on the first `:prepare` message.
      def class_decl_paths
        return {}.freeze if env.nil?

        result = {}
        env.class_decls.each do |rbs_name, entry|
          decl = self.class.primary_decl_for(entry)
          next if decl.nil?

          location = decl.location
          next if location.nil?

          buffer = location.buffer
          name = buffer.respond_to?(:name) ? buffer.name : nil
          next if name.nil?

          result[rbs_name.to_s.dup.freeze] = name.to_s.dup.freeze
        end
        result.freeze
      rescue ::RBS::BaseError
        {}.freeze
      end

      # @return [RBS::Definition, nil] the resolved instance definition for `class_name`, or nil when the
      #   class is unknown or its definition cannot be built (RBS may raise on broken hierarchies; we
      #   fail-soft and return nil so the caller can fall back).
      #
      # Built on demand from the (possibly cache-loaded) env; the in-memory `@instance_definition_cache`
      # keeps the per-process short-circuit. ADR-54 WD1 retired the definitions disk blob: given a cached
      # env, `Marshal.load`-ing every definition was measurably slower (and allocation-heavier) than
      # rebuilding the ones a run actually touches.
      def instance_definition(class_name)
        key = class_name.to_s
        return @instance_definition_cache[key] if @instance_definition_cache.key?(key)

        @instance_definition_cache[key] = build_instance_definition(class_name)
      end

      # @return [RBS::Definition::Method, nil]
      def instance_method(class_name:, method_name:)
        definition = instance_definition(class_name)
        return nil unless definition

        definition.methods[method_name.to_sym]
      end

      # @return [Array<Symbol>, nil] every instance-method name on `class_name` — own, inherited, and
      #   included — as resolved by `RBS::DefinitionBuilder`. Returns `nil` (NOT `[]`) when the class
      #   definition cannot be built so callers can tell "no methods" apart from "unknown class". Used by the
      #   `rigor:v1:conforms-to` presence check ({Rigor::RbsExtended::ConformanceChecker}).
      def instance_method_names(class_name)
        definition = instance_definition(class_name)
        return nil unless definition

        definition.methods.keys
      end

      # @return [RBS::Definition, nil] the built definition for the RBS interface `interface_name`
      #   (`_RewindableStream`), whose `.methods` are the required members (including interface-ancestor
      #   members). Returns `nil` when the name does not resolve to a loaded interface (a typo, or the
      #   defining library / sig set is not on the load path). Fail-soft on RBS build errors.
      def interface_definition(interface_name)
        rbs_name = parse_type_name(interface_name)
        return nil unless rbs_name
        return nil if env.nil?
        return nil unless env.interface_decls.key?(rbs_name)

        builder.build_interface(rbs_name)
      rescue ::RBS::BaseError
        nil
      end

      # @return [Array<Symbol>, nil] every method name required by the RBS interface `interface_name`, or nil
      #   when it does not resolve. Thin accessor over {#interface_definition} for the presence check.
      def interface_method_names(interface_name)
        interface_definition(interface_name)&.methods&.keys
      end

      # @param rbs_alias [RBS::Types::Alias] a type-alias reference (`string`, `int`, `range[int?]`, …)
      #   appearing in a method signature.
      # @return [RBS::Types::t, nil] the alias's aliased type one level out, with type arguments substituted
      #   for a generic alias (`string` → `::String | ::_ToStr`; `range[int?]` → `::Range[int?] |
      #   ::_Range[int?]`), or nil for an unresolved name. Lets a caller see through the alias that
      #   {Inference::RbsTypeTranslator} otherwise degrades to `untyped`, which is why an interface/alias
      #   parameter does not reject `nil`. `expand_alias2` handles the (rarer) generic case — a `range[T]`
      #   param previously fell back to "admits", which suppressed e.g. `MatchData#[](nil)`.
      def expand_type_alias(rbs_alias)
        return nil if env.nil?

        name = rbs_alias.name
        name = name.absolute! unless name.absolute?
        return nil unless env.type_alias_decls.key?(name)

        builder.expand_alias2(name, rbs_alias.args)
      rescue ::RBS::BaseError, StandardError
        nil
      end

      # @return [RBS::Definition, nil] the resolved singleton (class object) definition for `class_name`. The
      #   methods on this definition are the *class methods* of `class_name`, including those inherited from
      #   `Class` and `Module` for class types. Returns nil for unknown names and on RBS build errors
      #   (fail-soft).
      #
      # Built on demand from the env with a per-process memo; the same on-demand discipline as
      # {#instance_definition} (ADR-54 WD1).
      def singleton_definition(class_name)
        key = class_name.to_s
        return @singleton_definition_cache[key] if @singleton_definition_cache.key?(key)

        @singleton_definition_cache[key] = build_singleton_definition(class_name)
      end

      # @return [RBS::Definition::Method, nil] the class method on `class_name`. For example,
      #   `singleton_method(class_name: "Integer", method_name: :sqrt)` returns the definition for
      #   `Integer.sqrt`, while `singleton_method(class_name: "Foo", method_name: :new)` returns Class#new
      #   for any class type.
      def singleton_method(class_name:, method_name:)
        definition = singleton_definition(class_name)
        return nil unless definition

        definition.methods[method_name.to_sym]
      end

      # Slice 4 phase 2d. Returns the class's declared type-parameter names as Symbols (e.g., `[:Elem]` for
      # `Array`, `[:K, :V]` for `Hash`). Used by the dispatcher to build the substitution map from receiver
      # `type_args` into the method's return type. The instance definition is the canonical source because
      # singleton methods (e.g., `Array.new`) parameterize over the same `Elem` as instance methods.
      #
      # Returns an empty array for non-generic classes and for unknown names (the loader stays fail-soft).
      # NOTE: in the `rbs` gem, `RBS::Definition#type_params` returns `Array<Symbol>` directly, not the AST
      # `TypeParam` object (those live on the AST level).
      #
      # When `cache_store` is set, the loader fetches the entire type-parameter-name table once (per
      # process) through {Cache::RbsClassTypeParamNames.fetch} and answers point lookups from it. Cold runs
      # build the table once and persist it; warm runs (and a separate loader sharing the same Store) skip
      # the env walk entirely.
      def class_type_param_names(class_name)
        if cache_store
          key = class_name.to_s.delete_prefix("::")
          return type_param_names_table.fetch(key, []).dup
        end

        definition = instance_definition(class_name)
        return [] unless definition

        definition.type_params.dup
      end

      def class_ordering(lhs, rhs)
        @hierarchy.class_ordering(lhs, rhs)
      end

      # @return [Array<String>] every RBS-declared constant name (top-level prefixed, e.g., `"::Math::PI"`)
      #   currently loaded into the environment. Used by the cache producer that materialises the
      #   constant-type table; ordinary callers should keep using {#constant_type} for point lookups.
      def constant_names
        return [] if env.nil?

        env.constant_decls.keys.map(&:to_s)
      rescue ::RBS::BaseError
        []
      end

      # Yields `(name, entry)` for every RBS constant declaration currently loaded into the environment. The
      # cache producer uses this to materialise the constant-type table without going back through
      # {#constant_type} (which would recurse back into the cache when `cache_store` is set).
      def each_constant_decl
        return enum_for(:each_constant_decl) unless block_given?
        return if env.nil?

        env.constant_decls.each do |rbs_name, entry|
          yield rbs_name.to_s, entry
        end
      rescue ::RBS::BaseError
        # fail-soft: a broken RBS environment yields no entries.
      end

      # Slice A constant-value lookup. Returns the translated `Rigor::Type` for a non-class constant
      # declaration (`BUCKETS: Array[Symbol]`, `DEFAULT_PATH: String`, ...) or `nil` when no constant entry
      # exists for `name` in the loaded RBS environment. Callers MUST treat the return value as authoritative
      # when present and as "unknown" when nil; the loader does NOT consult the class declarations here —
      # class objects are still resolved through {#class_known?} and `Environment#singleton_for_name`.
      #
      # When `cache_store` is set, the loader fetches the entire translated constant table once (per
      # process) through {Cache::RbsConstantTable.fetch} and answers point lookups from it. Cold runs pay
      # the translation cost up-front and write the result to disk; warm runs skip the translation entirely
      # and pay only a `Marshal.load` of the table.
      def constant_type(name)
        rbs_name = parse_type_name(name)
        return nil unless rbs_name

        if cache_store
          constant_type_table[rbs_name.to_s]
        else
          translate_constant_decl(rbs_name)
        end
      rescue ::RBS::BaseError
        nil
      end

      # ADR-15 Phase 4b.x — eagerly drives every cached producer (plus the eager definitions tables, computed
      # from the cached env since ADR-54 WD1) so a subsequent worker Ractor can serve all of its RBS queries
      # without ever calling `RBS::EnvironmentLoader.new`. The loader path that calls
      # `EnvironmentLoader.new` transitively reads a chain of non-`Ractor.shareable?` module constants
      # (`RBS::EnvironmentLoader::DEFAULT_CORE_ROOT`, `RBS::Repository::DEFAULT_STDLIB_ROOT`,
      # `Gem::Requirement::DefaultRequirement`, …) and trips `Ractor::IsolationError`. Pre-warming on the
      # main Ractor — env blob loaded, derived tables built — keeps workers off that chain
      # (`RBS::DefinitionBuilder` over an already-built env does not touch it).
      #
      # No-op when `cache_store` is nil — without a Store the worker has no choice but to build env via the
      # loader, so the caller MUST ensure pool mode runs with caching enabled. Returns `self` so the call
      # chains cleanly from the `Runner` pre-spawn hook.
      def prewarm
        return self if cache_store.nil?

        env
        known_class_names_set
        constant_type_table
        type_param_names_table
        ancestor_names_table
        instance_definitions_table
        singleton_definitions_table
        self
      end

      # ADR-54 WD4 — the shared cache descriptor for every RBS-derived producer consulting this loader.
      # Building it digests every `.rbs` file under `signature_paths` + the vendored gem sigs, and the
      # result is identical across producers, so one build is memoised per loader (on `@state`, alongside
      # `:env` — the env itself is loader-lifetime-memoised, so this adds no new staleness class).
      def rbs_cache_descriptor
        @state[:rbs_cache_descriptor] ||= begin
          require_relative "../cache/rbs_descriptor"
          Cache::RbsDescriptor.build(self)
        end
      end

      # ADR-15 Phase 2b — return the loader's read-only query surface as a frozen, `Ractor.shareable?`
      # {Reflection} value object. Built lazily on first access; the loader memoises so repeated calls
      # return the same instance.
      #
      # The Reflection consumes the loader's already-warmed cache producers (or, when no `cache_store` is
      # set, eagerly walks the env). Once constructed, the Reflection carries the derived tables
      # independently and never re-consults the loader — making it safe to share across Ractors while the
      # loader stays per- process / per-Ractor for write-path operations.
      def reflection
        @state[:reflection] ||= begin
          require_relative "reflection"
          Environment::Reflection.new(
            known_class_names: known_class_names_set,
            instance_definitions: instance_definitions_table,
            singleton_definitions: singleton_definitions_table,
            type_param_names: type_param_names_table,
            constant_types: constant_type_table,
            ancestor_names: ancestor_names_table
          )
        end
      end

      private

      # The `::`-stripped names of every class/module entry whose declarations ALL originated from the given
      # sentinel buffer — i.e. names Rigor synthesized, not names the project declared. Reads off the built
      # env so the answer survives the marshalled env cache; shallowest-first. Empty when the env failed to
      # build.
      def names_synthesized_in(buffer_name)
        e = env
        return [] if e.nil?

        names = e.class_decls.filter_map do |type_name, entry|
          decls = entry_declarations(entry)
          next if decls.empty?
          next unless decls.all? { |decl| synthetic_decl?(decl, buffer_name) }

          type_name.to_s.sub(/\A::/, "")
        end
        names.sort_by { |name| name.count("::") }
      end

      # Collects the AST declaration nodes behind a `class_decls` entry across the supported RBS range (`rbs
      # >= 3.0, < 5.0`). RBS 4's `ModuleEntry` / `ClassEntry` expose `each_decl` yielding bare AST
      # declarations; RBS 3.x exposes `decls`, an array of `MultiEntry::D` wrappers whose `#decl` is the AST
      # declaration. The single-`decl` shape is handled defensively so the loader survives an rbs-gem minor
      # bump.
      def entry_declarations(entry)
        if entry.respond_to?(:each_decl)
          [].tap { |acc| entry.each_decl { |decl| acc << decl } }
        elsif entry.respond_to?(:decls)
          entry.decls.map { |d| d.respond_to?(:decl) ? d.decl : d }
        elsif entry.respond_to?(:decl)
          [entry.decl]
        else
          []
        end
      end

      # True when an AST declaration was emitted into `buffer_name` (one of the synthetic-source sentinels)
      # — identified by the buffer name on its location.
      def synthetic_decl?(decl, buffer_name)
        location = decl.respond_to?(:location) ? decl.location : nil
        location&.buffer&.name.to_s == buffer_name
      end

      def constant_type_table
        @constant_type_table ||= begin
          require_relative "../cache/rbs_constant_table"
          fetch_or_compute_producer(Cache::RbsConstantTable)
        end
      end

      def known_class_names_set
        @known_class_names_set ||= begin
          require_relative "../cache/rbs_known_class_names"
          fetch_or_compute_producer(Cache::RbsKnownClassNames)
        end
      end

      def type_param_names_table
        @type_param_names_table ||= begin
          require_relative "../cache/rbs_class_type_param_names"
          fetch_or_compute_producer(Cache::RbsClassTypeParamNames)
        end
      end

      # ADR-15 Phase 2b — the `Reflection` build path consumes these tables even when `cache_store` is nil
      # (e.g. tests that build a `Reflection` without a persistent cache). The helper routes through the
      # producer's `.fetch` when a store IS available, and falls back to the producer's `.compute`
      # otherwise.
      def fetch_or_compute_producer(producer)
        return producer.fetch(loader: self, store: cache_store) if cache_store

        producer.send(:compute, self)
      end

      # ADR-15 Phase 2b — `Hash<String, Array<String>>` of normalised ancestor chains per class. Consumes
      # the existing `RbsClassAncestorTable` producer when `cache_store` is set; falls back to the
      # producer's `compute` otherwise. Used by {#reflection}.
      def ancestor_names_table
        @ancestor_names_table ||= begin
          require_relative "../cache/rbs_class_ancestor_table"
          fetch_or_compute_producer(Cache::RbsClassAncestorTable)
        end
      end

      def cached_class_known(name)
        rbs_name = parse_type_name(name)
        return false unless rbs_name

        known_class_names_set.include?(rbs_name.to_s)
      rescue ::RBS::BaseError
        false
      end

      def translate_constant_decl(rbs_name)
        return nil if env.nil?

        entry = env.constant_decls[rbs_name]
        return nil unless entry

        translated = Inference::RbsTypeTranslator.translate(entry.decl.type)
        translated unless translated.is_a?(Type::Bot)
      end

      # The RBS environment for this loader. Memoised both on success AND on failure: when the env build
      # raises (typically `RBS::DuplicatedDeclarationError` because a `signature_paths:` entry redeclares a
      # constant or class already shipped by stdlib RBS), retrying on every subsequent `env` call would
      # re-parse and re-resolve the whole sig set per AST node touched during analysis, multiplying per-file
      # analysis cost by ~100x. Failures short-circuit to `nil` here and are surfaced to the user via
      # `warn_about_env_build_failure_once` so the broken `signature_paths:` entry is identifiable.
      def env
        return @state[:env] if @state[:env_loaded]

        @state[:env_loaded] = true
        @state[:env] = cache_store ? cached_env : build_env
        warn_about_quarantined_signatures
        @state[:env]
      rescue ::RBS::BaseError => e
        warn_about_env_build_failure_once(e)
        @state[:env] = nil
      end

      # Tell the user, once per run, which of their `signature_paths:` `.rbs` files were skipped because they
      # do not parse ({RbsLoader.add_project_signatures} quarantines them so the rest of the env survives). A
      # skipped file's types are absent, so calls into them read `Dynamic[top]` — silently, without this. This
      # is the visibility half of the fix: a shrinking diagnostic count must never be mistaken for a clean run
      # when it actually means "your sig/ stopped loading". No-op when `signature_paths:` is empty (the cost is
      # then a single empty-set check) or every file parses.
      #
      # `rigor check` ALSO reports this as the `rbs.coverage.quarantined-signature` diagnostic, which is what
      # reaches JSON / SARIF / CI annotations / the LSP. The banner is kept because the commands that build an
      # env WITHOUT producing a diagnostic stream (`coverage`, `sig-gen`) have no other channel, and a silently
      # degraded env is exactly what misleads there too.
      def warn_about_quarantined_signatures
        return if @state[:quarantine_warned]

        quarantined = quarantined_signatures
        return if quarantined.empty?

        @state[:quarantine_warned] = true
        listed = quarantined.first(QUARANTINE_WARN_LIMIT)
        more = quarantined.size - listed.size
        lines = listed.map { |_path, first_line| "    - #{first_line}" }
        lines << "    … and #{more} more" if more.positive?
        warn(
          "rigor: skipped #{quarantined.size} unparseable RBS file(s) under `signature_paths:`.\n  " \
          "They were QUARANTINED so the rest of your RBS env still loads, but the types they\n  " \
          "declare are absent — calls into them read `Dynamic[top]`, so coverage and diagnostics\n  " \
          "are reduced. Fix the parse error(s) to restore that coverage:\n" \
          "#{lines.join("\n")}"
        )
      end

      def warn_about_env_build_failure_once(error)
        return if @state[:env_build_warned]

        @state[:env_build_warned] = true
        first_line = error.message.to_s.lines.first.to_s.strip
        warn(
          "rigor: RBS environment build failed: #{error.class}: #{first_line}\n  " \
          "Likely cause: a `signature_paths:` entry redeclares a constant or class\n  " \
          "already shipped by Rigor's bundled RBS (Ruby core / stdlib / gem-bundled\n  " \
          "RBS / `data/vendored_gem_sigs/`). Rigor will continue analyzing with no\n  " \
          "RBS env in scope, so most type-of queries will return `Dynamic[top]` and\n  " \
          "most rule diagnostics will not fire. Remove the conflicting `.rbs` from\n  " \
          "your `signature_paths:` to restore type coverage."
        )
      end

      def cached_env
        require_relative "../cache/rbs_environment"
        Cache::RbsEnvironment.fetch(loader: self, store: cache_store)
      end

      # Full `Hash<String, RBS::Definition>` tables for the {#prewarm} / {#reflection} consumers (ADR-15
      # Phase 2b/4b.x), which need every definition materialised up front. Built from the (cached) env via
      # `RBS::DefinitionBuilder` — ADR-54 WD1 retired the disk blobs these used to `Marshal.load` (building
      # all definitions from a cached env is faster), so the eager-table cost is now a compute, not a load.
      # Keys stay in `RBS::TypeName#to_s` form (top-level prefixed `"::Hash"`) — the shape
      # {Environment::Reflection} documents.
      def instance_definitions_table
        @state[:instance_definitions_table] ||= build_definitions_table do |name|
          build_instance_definition(name)
        end
      end

      def singleton_definitions_table
        @state[:singleton_definitions_table] ||= build_definitions_table do |name|
          build_singleton_definition(name)
        end
      end

      def build_definitions_table
        table = {}
        each_known_class_name do |name|
          definition = yield(name)
          table[name] = definition if definition
        end
        table
      end

      def builder
        @state[:builder] ||= RBS::DefinitionBuilder.new(env: env)
      end

      def build_env
        self.class.build_env_for(
          libraries: @libraries,
          signature_paths: @signature_paths,
          virtual_rbs: @virtual_rbs
        )
      end

      def build_instance_definition(class_name)
        rbs_name = parse_type_name(class_name)
        return nil unless rbs_name
        return nil if env.nil?

        rbs_name = canonical_module_name(rbs_name)
        return nil unless env.class_decls.key?(rbs_name)

        builder.build_instance(rbs_name)
      rescue ::RBS::BaseError
        nil
      end

      def build_singleton_definition(class_name)
        rbs_name = parse_type_name(class_name)
        return nil unless rbs_name
        return nil if env.nil?

        rbs_name = canonical_module_name(rbs_name)
        return nil unless env.class_decls.key?(rbs_name)

        builder.build_singleton(rbs_name)
      rescue ::RBS::BaseError
        nil
      end

      # Resolve an RBS class/module ALIAS to its canonical declared name. `class Mutex = Thread::Mutex`
      # lives only in `class_alias_decls`, so `class_known?` reports it (it checks that table) but the
      # definition builder — which only knows `class_decls` — could not enumerate its methods, leaving alias
      # classes (`Mutex`, and any `X = Y`) with no resolvable method surface. Normalising via the env (RBS's
      # own alias resolution) before the `class_decls` guard fixes dispatch AND the `call.undefined-method`
      # existence check on them. A non-alias name, or one that does not normalise, is returned unchanged.
      def canonical_module_name(rbs_name)
        return rbs_name unless env.class_alias_decls.key?(rbs_name)

        env.normalize_module_name?(rbs_name) || rbs_name
      rescue ::RBS::BaseError
        rbs_name
      end

      # Memoised on `@state` (the per-loader store also holding `:env` / `:builder`): `RBS::TypeName.parse`
      # is a pure, deterministic function of the normalised string, and the `RBS::TypeName` it returns is a
      # frozen value object safe to share across callers (every consumer only reads it —
      # `env.class_decls.key?` / `builder.build_*`). The same handful of class names are parsed on nearly
      # every call-site dispatch, so this was a top allocation site; caching the immutable result (nil
      # included) removes it.
      def parse_type_name(name)
        s = name.to_s
        return nil if s.empty?

        s = "::#{s}" unless s.start_with?("::")
        cache = (@state[:type_name_cache] ||= {})
        return cache[s] if cache.key?(s)

        cache[s] =
          begin
            RBS::TypeName.parse(s)
          rescue ::RBS::BaseError
            nil
          end
      end

      def compute_class_known(name)
        rbs_name = parse_type_name(name)
        return false unless rbs_name
        return false if env.nil?

        # `RBS::Environment#class_decls` after `resolve_type_names` holds entries for both classes AND
        # modules; the gem unifies them under one map post-resolution. Aliases live in their own table.
        env.class_decls.key?(rbs_name) || env.class_alias_decls.key?(rbs_name)
      rescue ::RBS::BaseError
        false
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
