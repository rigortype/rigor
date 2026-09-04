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
    # rubocop:disable-next Metrics/ClassLength
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

      # The buffer name `Cache::RbsEnvironmentMarshalPatch` reconstructs every `RBS::Location` behind on a
      # cache HIT. Never a real path, so it must never be reported as one (issue #696).
      CACHED_LOCATION_BUFFER_NAME = "<cached>"

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
          libraries = libraries_without_shadowed_bigdecimal_math(libraries)
          loaded_libraries = libraries.select do |library|
            rbs_loader.has_library?(library: library, version: nil)
          end
          loaded_libraries.each do |library|
            rbs_loader.add(library: library, version: nil)
          end
          # Project `signature_paths:` are loaded per-file by {.add_project_signatures} AFTER `from_loader`,
          # NOT added to the loader here: `RBS::Environment.from_loader` parses every added file all-or-nothing,
          # so one unparseable user `.rbs` raises `RBS::ParsingError` and collapses the WHOLE env to nil (every
          # type-of query then degrades to `Dynamic[top]` — the "sig looks harmful" failure of the 2026-07-06
          # mastodon coverage note). Per-file loading quarantines the broken file instead. Vendored / core-overlay
          # sigs are Rigor-shipped and trusted, so they stay on the loader's fast batch path.
          add_bundled_signatures(rbs_loader, loaded_libraries.to_set(&:to_s))
          env = RBS::Environment.from_loader(rbs_loader)
          add_project_signatures(env, signature_paths)
          add_virtual_rbs(env, virtual_rbs)
          synthesize_missing_namespaces(env)
          env, resolved = resolve_quarantining_virtual_collisions(env, virtual_rbs)
          stub_missing_referenced_types(env, resolved, project_sig_files(signature_paths))
        end

        # rbs ships `stdlib/bigdecimal/` and `stdlib/bigdecimal-math/` as two libraries, so
        # `Environment::DEFAULT_LIBRARIES` names both. But `RBS::EnvironmentLoader` resolves a library to an
        # INSTALLED GEM's `sig/` in preference to rbs's own `stdlib/` copy, and the `bigdecimal` gem has
        # shipped `sig/big_math.rbs` — declaring the very same `BigMath` module — since 4.0. On such a host
        # both declarations land in one environment, `RBS::DefinitionBuilder` raises
        # `DuplicatedMethodDefinitionError` on `BigMath.E`, and the WHOLE module silently degrades to
        # `Dynamic[top]` (issue #299) — every `BigMath` call, real method and typo alike, stops being
        # witnessed.
        #
        # `bigdecimal-math` is the entry to drop, not `bigdecimal`: the gem's copy is maintained alongside
        # the implementation, types `log10` / `log1p` / `expm1` / `tan` / `tanh` (which rbs's copy omits
        # outright), and accepts `real | BigDecimal` where rbs's accepts only `BigDecimal`. Dropping it is
        # therefore a strict typing gain, not a trade.
        #
        # Host-dependent by construction, and deliberately so: where `bigdecimal` resolves to rbs's own
        # `stdlib/bigdecimal/` (an older gem with no `sig/`, or no gem at all), nothing collides, nothing is
        # dropped, and `bigdecimal-math` still supplies `BigMath`.
        BIGDECIMAL_LIBRARY = "bigdecimal"
        private_constant :BIGDECIMAL_LIBRARY
        BIGDECIMAL_MATH_LIBRARY = "bigdecimal-math"
        private_constant :BIGDECIMAL_MATH_LIBRARY
        # The one basename that decides it: `BigMath` lives in `big_math.rbs` on both sides.
        BIG_MATH_SIG_BASENAME = "big_math.rbs"
        private_constant :BIG_MATH_SIG_BASENAME

        # @param libraries [Array<String>] the resolved library list, `DEFAULT_LIBRARIES` included.
        # @return [Array<String>] the same list, minus `bigdecimal-math` when `bigdecimal` already brings
        #   `BigMath` in.
        def libraries_without_shadowed_bigdecimal_math(libraries)
          return libraries unless libraries.include?(BIGDECIMAL_LIBRARY) && libraries.include?(BIGDECIMAL_MATH_LIBRARY)
          return libraries unless bigdecimal_library_declares_big_math?

          libraries - [BIGDECIMAL_MATH_LIBRARY]
        end

        # Resolves `library: "bigdecimal"` on a THROWAWAY loader (never the one building the env) and reports
        # whether any directory it resolves to ships `big_math.rbs`. Fails soft to `false`: an unresolvable
        # library must not take the whole environment build down, and keeping both entries is the
        # pre-existing behaviour.
        def bigdecimal_library_declares_big_math?
          probe = ::RBS::EnvironmentLoader.new(core_root: nil)
          return false unless probe.has_library?(library: BIGDECIMAL_LIBRARY, version: nil)

          probe.add(library: BIGDECIMAL_LIBRARY, version: nil)
          shadowed = false
          probe.each_dir { |_source, dir| shadowed ||= dir.join(BIG_MATH_SIG_BASENAME).file? }
          shadowed
        rescue StandardError
          false
        end

        # True when `content` parses as an RBS signature. {#virtual_rbs_collision_quarantined} uses this to
        # tell a collision-dropped virtual entry (parses, but absent from the env) from a parse-failed one
        # (the synthesizer's own WD6 skip, reported separately).
        def parseable_rbs?(content)
          # Pre-parser encoding guard ({.invalid_encoding?}): invalid UTF-8 raises `ArgumentError` (not
          # `ParsingError`) out of `RBS::Parser.magic_comment`'s regex on rbs 4.1, escaping the rescue below,
          # and could hang the C lexer outright on the older releases the gemspec supports.
          return false if invalid_encoding?(content)

          ::RBS::Parser.parse_signature(::RBS::Buffer.new(name: "(rigor: virtual parse check)", content: content))
          true
        rescue ::RBS::BaseError
          false
        end

        # Backstop for a virtual-vs-anything `RBS::DuplicatedDeclarationError` that only materialises at
        # `resolve_type_names` (which rebuilds the env from `sources`). {.add_virtual_rbs}'s transactional
        # rescue already handles the add-time case — empirically everything on rbs 4.x — but the rbs gemspec
        # range spans `>= 3.0, < 5.0` (ADR-79) and WHERE duplicate detection fires is an rbs-internal choice
        # this code must not depend on. Resolution rule is the same as the add-time path: the explicit
        # signature wins, the colliding VIRTUAL buffer is dropped whole (`RBS::Environment#unload`) and
        # resolution retries; every pass removes at least one virtual buffer, so the loop is bounded by the
        # virtual-entry count. A duplicate involving no virtual buffer (sig-vs-sig), or an env without
        # `#unload` (rbs 3.x), re-raises into the existing one-warning degrade path.
        #
        # The dropped set is not returned: consumers recover it from the built env via
        # {#virtual_rbs_collision_quarantined}, which also works on a cache HIT where this build never ran.
        def resolve_quarantining_virtual_collisions(env, virtual_rbs)
          virtual_names = virtual_rbs.to_set { |name, _content| name.to_s }
          (virtual_names.size + 1).times do
            return [env, env.resolve_type_names]
          rescue ::RBS::DuplicatedDeclarationError => e
            raise unless env.respond_to?(:unload)

            culprits = e.decls.filter_map { |decl| decl.location&.buffer&.name }
                        .uniq.select { |name| virtual_names.include?(name) }
            raise if culprits.empty?

            env = env.unload(culprits)
          end
          [env, env.resolve_type_names]
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
        # Detection reads the PROJECT declarations and mirrors rbs's own membership test
        # ({.unresolved_referenced_types}); it is bounded to `signature_paths` classes (stdlib / vendored RBS
        # is well-formed) and to {MAX_STUB_PASSES} iterations — a fresh stub can expose a deeper reference the
        # first pass could not see past, but empty stubs reference nothing, so the fixpoint converges quickly.
        MAX_STUB_PASSES = 5

        def stub_missing_referenced_types(base_env, resolved, project_files)
          return resolved if project_files.empty?

          previous = nil
          MAX_STUB_PASSES.times do
            missing = unresolved_referenced_types(resolved, project_files)
            break if missing.empty?

            # Bound the fixpoint by PROGRESS, not by the cap alone. A pass that appends no declaration, or
            # that re-detects the set it already saw, cannot converge — and before this guard the cap was the
            # only stop, so the pathological input paid the full detection sweep five times over (measured on
            # herb: five passes, nothing synthesized). The cap stays as the backstop for a genuinely deepening
            # chain of references.
            current = missing.to_set
            break if current == previous || !append_stub_declarations(base_env, missing)

            previous = current
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

        # The quarantine note for a file rejected by {.invalid_encoding?} — worded to be distinct from any
        # rbs-emitted parse error so specs (and users) can tell Rigor's pre-parser skip from the parser's own
        # UTF-8 diagnostics.
        INVALID_ENCODING_NOTE = "not valid UTF-8 — skipped before reaching the RBS parser"

        # Pre-parser guard for content Rigor hands to `RBS::Parser`. On rbs 4.1+ an invalid UTF-8 byte is a
        # clean `ParsingError` (ruby/rbs#2983), but on the older releases the gemspec supports (`>= 3.0,
        # < 5.0`) the C lexer could infinite-loop or abort on it (fixed upstream in ruby/rbs#2973) — a hang no
        # `rescue` can catch, and the one failure mode the quarantine's fail-soft rescues cannot absorb. So
        # the check runs before the parser on every rbs version: uniform behaviour, and the quarantine note
        # stays actionable ("fix the file's encoding") rather than version-dependent.
        def invalid_encoding?(content)
          !content.valid_encoding?
        end

        # Parse one project `.rbs` into `[buffer, directives, decls]`, or nil when it is unparseable /
        # unreadable / not valid UTF-8. Mirrors `RBS::EnvironmentLoader#each_signature`'s per-file parse so
        # the decls register identically to the loader's batch path.
        def parse_signature_file(file)
          content = File.read(file, encoding: "UTF-8")
          return nil if invalid_encoding?(content)

          buffer = ::RBS::Buffer.new(name: file, content: content)
          _buffer, directives, decls = ::RBS::Parser.parse_signature(buffer)
          [buffer, directives, decls]
        rescue ::RBS::ParsingError, Errno::ENOENT, Errno::EISDIR, Errno::EACCES
          nil
        end

        # The project `signature_paths:` files that FAIL to parse (or are not valid UTF-8), as
        # `[absolute_path, first_error_line]` pairs (sorted, deterministic). Detection is independent of
        # {.add_project_signatures} so the warning fires even on a cache hit (where the env was already built
        # with the file quarantined). Cheap: it only re-parses the user's own (usually small) `sig/` set, and
        # returns empty immediately when there is no `signature_paths:`.
        def quarantined_project_signatures(signature_paths)
          project_sig_files(signature_paths).sort.filter_map do |file|
            # The note carries the path itself because the warn composer prints only this element — a
            # `ParsingError` message embeds its `path:line:` prefix, so the composer never adds one.
            content = File.read(file, encoding: "UTF-8")
            next [file, "#{file}: #{INVALID_ENCODING_NOTE}"] if invalid_encoding?(content)

            buffer = ::RBS::Buffer.new(name: file, content: content)
            ::RBS::Parser.parse_signature(buffer)
            nil
          rescue ::RBS::ParsingError => e
            [file, e.message.to_s.lines.first.to_s.strip]
          rescue Errno::ENOENT, Errno::EISDIR, Errno::EACCES
            nil
          end
        end

        # The `::`-stripped names of every type a PROJECT signature references that no loaded declaration
        # provides — the input to {.append_stub_declarations}.
        #
        # Detection READS the declarations; it does not build them. Until #207 it built every project class
        # instance- and singleton-side with a throwaway `RBS::DefinitionBuilder` and recovered the name from
        # the raised `NoTypeFoundError` — correct by construction, and **7.84M allocations, a third of a cold
        # `check lib`** on Rigor's own tree, to find nothing once `sig/` is self-consistent. The walk below
        # costs ~21k.
        #
        # It mirrors rbs's raise sites, so the answer is the builder's:
        #
        # * `DefinitionBuilder#validate_type_presence` over the ARGS of a super class, a module `self` type,
        #   and a mixin. The name itself is deliberately NOT checked: a missing super class or mixin raises
        #   `NoSuperclassFoundError` / `NoMixinFoundError`, which this pass has never stubbed.
        # * `VarianceCalculator#type` over every method type `validate_type_params` reaches, which raises for
        #   `ClassInstance` / `Interface` / `Alias` only. It skips `initialize`, and it is not called for the
        #   singleton side — so a name reachable only through `def initialize:` or `def self.x:` is not
        #   reported here, exactly as the builder did not report it. Stubbing those names anyway cost
        #   allocations on the corpus and changed no diagnostic.
        #
        # Membership is decided with the builder's own predicate ({.declared_reference?}), so a name reported
        # here is one no declaration in the env provides. A resolvable name can never be reported, which is
        # what keeps the stub safe: ADR-5 tier 2 trades precision for a fail-soft, and a stub for a name that
        # WOULD have resolved would shadow a real type instead.
        #
        # One reduction in scope. The builder also walked each project class's ANCESTORS, so a dangling
        # reference inside a *gem's* signature reachable from a project class was reported too; this walk
        # reads project declarations only. No such name occurs across the eight RBS-shipping projects the
        # change was measured on, and the cost of missing one is the fail-soft `Dynamic` ADR-5 tier 2 already
        # accepts — not a false diagnostic. A project INTERFACE's own dangling reference is likewise not
        # reported, and likewise was not by the builder (`validate_type_params` does not variance-walk the
        # methods a class imports from an interface) — pinned by spec so the two stay together.
        #
        # Equivalence with the builder sweep is pinned by spec, which keeps the sweep as its oracle. Full
        # evaluation: `docs/notes/20260730-stub-pass1-static-detection-evaluation.md`.
        def unresolved_referenced_types(env, project_files)
          missing = {}
          checked = {}
          env.class_decls.each_value do |entry|
            next unless project_entry?(entry, project_files)

            entry_declarations(entry).each { |decl| collect_declaration_references(env, decl, missing, checked) }
          end
          missing.keys
        end

        # Decl-level references the builder validates: a super class's / module self type's / mixin's type
        # ARGUMENTS, plus every member. `super_class` is a `Declarations::Class` accessor and `self_types` a
        # `Declarations::Module` one, so both are reached behind a shape check.
        def collect_declaration_references(env, decl, missing, checked)
          if decl.respond_to?(:super_class)
            decl.super_class&.args&.each { |arg| collect_type_references(env, arg, missing, checked) }
          end
          if decl.respond_to?(:self_types)
            decl.self_types&.each do |self_type|
              self_type.args.each { |arg| collect_type_references(env, arg, missing, checked) }
            end
          end
          collect_member_references(env, decl.members, missing, checked)
        end

        # Member-level references. `initialize` and the singleton side are skipped because
        # `validate_type_params` never reaches them (see {.unresolved_referenced_types}); `:singleton_instance`
        # (`def self?.x`) defines the instance side too, so it is NOT skipped.
        def collect_member_references(env, members, missing, checked)
          members.each do |member|
            next if member.respond_to?(:kind) && member.kind == :singleton

            case member
            when ::RBS::AST::Members::MethodDefinition
              next if member.name == :initialize

              member.overloads.each do |overload|
                collect_type_references(env, overload.method_type, missing, checked)
              end
            when ::RBS::AST::Members::AttrReader, ::RBS::AST::Members::AttrWriter,
                 ::RBS::AST::Members::AttrAccessor
              collect_type_references(env, member.type, missing, checked)
            when ::RBS::AST::Members::Include, ::RBS::AST::Members::Extend,
                 ::RBS::AST::Members::Prepend
              member.args.each { |arg| collect_type_references(env, arg, missing, checked) }
            end
          end
        end

        # Walks one type (or method type) and appends the names no declaration provides. Only the three node
        # classes `VarianceCalculator#type` raises for carry a checkable name; everything else is traversed for
        # the types nested inside it.
        def collect_type_references(env, type, missing, checked)
          return if type.nil?

          case type
          when ::RBS::Types::ClassInstance, ::RBS::Types::Interface, ::RBS::Types::Alias
            name = type.name
            name = name.absolute! unless name.absolute?
            missing[name.to_s.sub(/\A::/, "")] = true unless declared_reference?(env, name, checked)
          end
          return unless type.respond_to?(:each_type)

          type.each_type do |nested|
            collect_type_references(env, nested, missing, checked)
          end
        end

        # `DefinitionBuilder#validate_type_name`'s membership test, memoised per env walk (a project's method
        # signatures name the same handful of types over and over). A name whose normalization raises is
        # treated as declared: repairing it is not this pass's job, and a wrong stub is the worse failure.
        def declared_reference?(env, name, checked)
          key = name.to_s
          return checked[key] if checked.key?(key)

          checked[key] = begin
            env.type_name?(env.normalize_type_name(name))
          rescue StandardError
            true
          end
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

        # Collects the AST declaration nodes behind a `class_decls` entry across the supported RBS range (`rbs
        # >= 3.0, < 5.0`). RBS 4's `ModuleEntry` / `ClassEntry` expose `each_decl` yielding bare AST
        # declarations; RBS 3.x exposes `decls`, an array of `MultiEntry::D` wrappers whose `#decl` is the AST
        # declaration. The single-`decl` shape is handled defensively so the loader survives an rbs-gem minor
        # bump. Class-side because both the env-build detection walk and the instance-side
        # `#names_synthesized_in` need it, and the guard must stay single-rooted.
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
        # need) to the pre-resolve env, tagged with {SYNTHETIC_STUB_BUFFER}. Returns true when at least one
        # declaration landed, so {.stub_missing_referenced_types} can stop on a pass that made no progress.
        #
        # Each name gets the declaration kind its own syntax requires ({.stub_declaration_for}), and each
        # declaration is validated ALONE before it joins the buffer. Declaring every name `class` — the shape
        # before #237 — made a dangling interface (`_Foo`) or type-alias (`foo`) reference unparseable, and
        # since the batch shares one buffer the `RBS::BaseError` rescue below then discarded every stub in it,
        # well-formed ones included. Measured on herb, whose 74 missing names are all dangling type aliases:
        # the pass synthesized nothing at all, leaving the project's 48 signature files inert, while still
        # paying for the detection sweep. A per-declaration check costs one small parse per name and bounds
        # the damage of one bad name to itself.
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
          return false if names.empty?

          source = names.sort_by { |n| n.count(":") }.filter_map do |name|
            declaration = stub_declaration_for(name, names)
            declaration if parseable_rbs?(declaration)
          end.join
          return false if source.empty?

          buffer = ::RBS::Buffer.new(name: SYNTHETIC_STUB_BUFFER, content: source)
          _, directives, decls = ::RBS::Parser.parse_signature(buffer)
          add_parsed_decls(base_env, buffer, directives, decls)
          true
        rescue ::RBS::BaseError
          false
        end

        # The declaration one stubbed name needs, keyed on the syntax of its leaf:
        #
        # * a name other stubbed names nest inside is a namespace, so `module`;
        # * an RBS interface name (`_Foo`) may only be declared `interface`;
        # * a type-alias name (`foo`) may only be declared `type`, and aliases `untyped` so a value of that
        #   type reads as `Dynamic[Top]` — the honest answer for a type Rigor invented;
        # * anything else is `class` (referenced types appear in instance position far more often than as
        #   mixins).
        #
        # The interface stub is FP-safe without joining {#synthesized_type_names}: {RbsTypeTranslator} maps
        # every interface type to untyped, and the nil / non-nil acceptance guards in {Analysis::CheckRules}
        # treat a method-less interface as accepting everything.
        def stub_declaration_for(name, names)
          leaf = name.split("::").last.to_s
          if names.any? { |other| other != name && other.start_with?("#{name}::") }
            "module #{name}\nend\n"
          elsif leaf.start_with?("_")
            "interface #{name}\nend\n"
          elsif leaf.match?(/\A[a-z]/)
            "type #{name} = untyped\n"
          else
            "class #{name}\nend\n"
          end
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
            # Same pre-parser guard as {.parse_signature_file}: a synthesizer echoing project bytes can carry
            # invalid UTF-8, which pre-4.1 rbs lexers could hang on — and a hang escapes the rescue below.
            next if invalid_encoding?(content.to_s)

            buffer = ::RBS::Buffer.new(name: filename.to_s, content: content.to_s)
            _, directives, decls = ::RBS::Parser.parse_signature(buffer)
            add_parsed_decls(env, buffer, directives, decls)
          rescue ::RBS::BaseError
            # WD6 fail-soft: a single broken virtual RBS contribution does not pull the whole env down — for
            # a parse error, skipping the entry is enough. But `RBS::Environment#add_source` appends to
            # `env.sources` BEFORE inserting decls, so when the raise is a mid-insert
            # `RBS::DuplicatedDeclarationError` (the entry declares a constant the project's own `sig/`
            # already declares — the expected state for a project migrating between `sig/` and inline
            # annotations, not an authoring error), the POISONED SOURCE is left behind, and
            # `resolve_type_names` — which rebuilds the env from `sources` — re-raises the same error outside
            # this rescue and collapses the WHOLE env to nil (measured on herb: 1,490 classes → 0, `require`
            # itself stopped resolving, 74 false `call.unresolved-toplevel`). Make the skip transactional:
            # drop the poisoned source. The explicit `.rbs` declaration wins — the spec keeps standalone
            # `.rbs` files "the preferred place for complete type definitions" (`overview.md`) — and
            # {#warn_about_virtual_rbs_collisions} names the dropped file. `sources` is the rbs 4.x shape;
            # under the 3.x API this degrades to today's behaviour.
            env.sources.reject! { |source| source.buffer.name == buffer.name } if env.respond_to?(:sources)
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

        # Bundled signature sources that SUPPLEMENT a stdlib library's own declarations rather than stand
        # alone: each re-opens a class the named `RBS::EnvironmentLoader` library declares with a mixin
        # (`CGI::QueryExtension`), a superclass (`Prism::Result`), or an `| ...` overload continuation
        # (`StringScanner#[]`, `Resolv#initialize`). Loading one into an environment built WITHOUT its
        # library does not fail the env build — `RBS::DefinitionBuilder` raises later
        # (`NoMixinFoundError` / `NoSuperclassFoundError` / `InvalidOverloadMethodError`), Rigor fails soft,
        # and the WHOLE re-opened class silently degrades to `Dynamic[top]` (issue #299's narrow-environment
        # tail). So each supplement is loaded ONLY when its library actually resolved; in production every
        # gating library is in `Environment::DEFAULT_LIBRARIES`, so the full environment is unchanged.
        #
        # `core_overlay/pathname.rbs` also carries an `| ...` continuation but is deliberately NOT listed:
        # its base (`Pathname#expand_path`) lives in rbs's `core/pathname.rbs` on every supported rbs
        # release (3.10 / 4.0 / 4.1), so the continuation is safe — and applicable — with no library loaded.
        #
        # Keyed by `data/vendored_gem_sigs/` directory basename.
        LIBRARY_SUPPLEMENT_VENDORED_DIRS = {
          "cgi" => "cgi",
          "prism" => "prism"
        }.freeze
        private_constant :LIBRARY_SUPPLEMENT_VENDORED_DIRS

        # Keyed by `data/core_overlay/` file basename. Files not listed here re-open Ruby-core classes (or
        # add self-contained declarations) and stay unconditional.
        LIBRARY_SUPPLEMENT_CORE_OVERLAYS = {
          "resolv.rbs" => "resolv",
          "string_scanner.rbs" => "strscan"
        }.freeze
        private_constant :LIBRARY_SUPPLEMENT_CORE_OVERLAYS

        # Adds the Rigor-shipped signature sources to `rbs_loader`: every `data/vendored_gem_sigs/<gem>/`
        # directory, then the `data/core_overlay/` files — the overlay LAST so an upstream declaration
        # always wins on conflict (these reopenings only fill genuine holes, e.g. `Numeric#to_f`/`to_i`/
        # `to_r`, which upstream RBS declares on the concrete subclasses but not on the abstract `Numeric`
        # that Rigor's arithmetic-chain widening produces). The overlay is added per-file, not
        # per-directory, because the `LIBRARY_SUPPLEMENT_CORE_OVERLAYS` files must be gated individually.
        #
        # @param loaded_library_names [Set<String>] libraries that actually resolved on this loader.
        def add_bundled_signatures(rbs_loader, loaded_library_names)
          vendored_gem_sig_paths.each do |path|
            next unless path.directory?
            next unless supplement_dependency_loaded?(LIBRARY_SUPPLEMENT_VENDORED_DIRS, path, loaded_library_names)

            rbs_loader.add(path: path)
          end
          core_overlay_sig_paths.each do |dir|
            next unless dir.directory?

            dir.children.sort.each do |file|
              next unless file.file? && file.extname == ".rbs"
              next unless supplement_dependency_loaded?(LIBRARY_SUPPLEMENT_CORE_OVERLAYS, file, loaded_library_names)

              rbs_loader.add(path: file)
            end
          end
        end

        # @param supplements [Hash{String => String}] basename → gating library map.
        # @param path [Pathname] the vendored directory or overlay file to test.
        # @param loaded_library_names [Set<String>] libraries that actually resolved on this loader.
        # @return [Boolean] true when `path` carries no library dependency, or its library loaded.
        def supplement_dependency_loaded?(supplements, path, loaded_library_names)
          library = supplements[path.basename.to_s]
          library.nil? || loaded_library_names.include?(library)
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

        # @param path [String, Pathname] typically an entry from an {RbsLoader} instance's
        #   {#signature_paths}.
        # @return [Boolean] whether `path` sits under the bundled gem-overlay root — what
        #   `CheckRules::GEM_OVERLAY_OPEN_RECEIVERS`'s gate consults so that a class name's membership in
        #   that list alone never grants the open-receiver exemption; the overlay directory that made the
        #   entry true must have actually loaded THIS run too (issue #632, tracked further by #660).
        #   `GEM_OVERLAY_SIGS_ROOT` is defined inside this `class << self` block, so it is reachable from
        #   here directly but NOT as `RbsLoader::GEM_OVERLAY_SIGS_ROOT` from outside — this method is the
        #   public seam callers outside this class use instead of reaching for the constant themselves.
        def under_gem_overlay_root?(path)
          path.to_s.start_with?("#{GEM_OVERLAY_SIGS_ROOT}/")
        end

        # The twin of {.under_gem_overlay_root?}, for the OTHER copy of the same declarations. ADR-72 ships
        # each overlay's surface twice — as `data/gem_overlay/<gem>/` and as the opt-in plugin's own `sig/` —
        # and a project can reach the second WITHOUT the plugin registry, by naming it in `signature_paths:`
        # (issue #672). Two callers ask, for different reasons:
        #
        # - `Environment.gem_overlay_paths` asks per gem, so the overlay stands down instead of loading
        #   alongside the twin and collapsing every class they share;
        # - `CheckRules#gem_overlay_loaded?` asks across all of them, because the twin's `sig/` carries no
        #   plugin manifest, so `open_receivers:` cannot protect the partial `ActiveSupport::Duration`
        #   declaration it nonetheless loads.
        #
        # **Both ask what an entry LOADS, not what it looks like.** Comparing path strings is wrong in both
        # directions, and the false-positive direction is the expensive one: an entry naming the twin's
        # `.rbs` FILE, or a subdirectory of the twin that does not exist, matches as a string while the
        # loader reads nothing from it ({.project_sig_files} takes directories only — the same fact
        # {Rigor::SignaturePathAudit} reports as `:not_directory` / `:missing`). Standing an overlay down for
        # those leaves the project with NEITHER copy, so ordinary `3.minutes` draws `call.undefined-method`
        # on correct code. The quiet direction is the mirror: a symlink to the twin, or a case-variant
        # spelling of it where the filesystem folds case, loads the twin while matching no prefix. Asking
        # {.project_sig_files} for the twin's files and canonicalising both sides answers both.
        #
        # Lives here rather than on {Rigor::Environment} because it is an internal seam, not ADR-2 public
        # API: `spec/rigor/public_api_drift_spec.rb` pins `Environment`'s singleton surface, and a predicate
        # two call sites share is not a promise to plugin authors. Here it sits beside the overlay-side
        # answer to the very same question, on the class that already owns the overlay's layout
        # ({GEM_OVERLAY_SIGS_ROOT}, {.gem_overlay_sig_paths}).
        #
        # @param signature_paths [Array<String, Pathname>] typically an {RbsLoader} instance's
        #   {#signature_paths}. Takes the whole list rather than one entry so the twin's file set resolves
        #   once per question — `CheckRules` asks it per `ActiveSupport::Duration` receiver.
        def gem_overlay_twin_signatures_loaded?(signature_paths)
          # `GEM_OVERLAY_PLUGIN_IDS` is ADR-72 eligibility policy and stays owned by `Environment`; it is
          # read here only to enumerate which bundled plugins HAVE an overlay twin.
          GEM_OVERLAY_PLUGIN_IDS.each_value.any? do |plugin_id|
            bundled_overlay_twin_signatures_loaded?(plugin_id, signature_paths)
          end
        end

        # The per-plugin half of {.gem_overlay_twin_signatures_loaded?}. `Environment` owns the gem → plugin
        # id mapping and passes the id; this resolves the id to the engine's own bundled `sig/` and answers
        # the filesystem question.
        #
        # @param plugin_id [String] a manifest id, e.g. `"activesupport-core-ext"`.
        def bundled_overlay_twin_signatures_loaded?(plugin_id, signature_paths)
          return false if signature_paths.nil? || signature_paths.empty?

          # In-method for the reason `Plugin::FirstParty` documents at its own `require`: the plugin
          # subsystem's load graph reaches back into the environment, and only the overlay path calls this —
          # a run with no eligible overlay gem never pays them.
          require_relative "../plugin/first_party"
          require_relative "../plugin/loader"
          twin = Plugin::Loader.bundled_plugin_sig_path("#{Plugin::FirstParty::GEM_PREFIX}#{plugin_id}")
          return false unless twin

          twin_files = project_sig_files([twin]).filter_map { |file| canonical_real_path(file) }
          return false if twin_files.empty?

          signature_paths.any? { |entry| signature_entry_loads?(entry, twin_files) }
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

        # Everything below is internal to {.bundled_overlay_twin_signatures_loaded?}. `private` (not
        # `private_class_method`) because inside `class << self` these are instance methods of the
        # singleton class; `private_class_method` looks for them one level further out and raises NameError
        # at load. Placed last so the modifier cannot capture a method that is meant to be reachable.
        private

        # Whether one `signature_paths:` entry is a directory the loader would read one of `twin_files`
        # from. Both sides are canonicalised first, which is what makes a symlinked or case-variant
        # spelling of the twin answer the same as the twin itself.
        def signature_entry_loads?(entry, twin_files)
          dir = canonical_real_path(entry)
          return false unless dir && File.directory?(dir)

          prefix = "#{dir}#{File::SEPARATOR}"
          twin_files.any? { |file| file.start_with?(prefix) }
        end

        # `File.realpath` rather than `File.expand_path`: it resolves symlinks and, on a case-insensitive
        # filesystem, the on-disk spelling — the two ways a path can reach the twin's files without looking
        # like it. It raises for a path that does not exist, which is the answer we want (an entry that
        # resolves to nothing loads nothing), so the rescue returns nil rather than falling back to a
        # lexical expansion that would resurrect the string match.
        def canonical_real_path(path)
          File.realpath(path.to_s)
        rescue SystemCallError
          nil
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
        # names currently consulted: `:env`, `:env_loaded`, `:env_build_warned`, `:definition_build_warned`,
        # `:definition_build_details`, `:definition_build_reported`, `:definition_build_failures`,
        # `:internal_demand`, `:builder`, `:reflection`, `:instance_definitions_table`,
        # `:singleton_definitions_table`.
        # Constructed via `Hash.new` (NOT a `{ ... }` literal) so Rigor's `HashShape` narrowing doesn't
        # infer a fixed key set from the initial state and fold post-initial slot reads (e.g.
        # `@state[:env_loaded]`) to a constant `nil`.
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

      # Issue #735 — the class / module names whose PRIMARY declaration lives under the project's own
      # `signature_paths:`, top-level prefix stripped ("::Admin::Widget" reads back as "Admin::Widget").
      #
      # The distinction it exists to draw: a BUNDLED declaration (core, stdlib, a gem's RBS) is
      # authoritative about its class, so a project `def` on that class is a monkey-patch and ADR-17 has
      # the analyzer report it rather than adopt it. A declaration the project wrote itself — by hand or
      # through `rigor sig-gen --write` — is a sidecar of the same source tree, and a `def` in another of
      # the project's own files is not a monkey-patch, just the second file of an ordinary class. Reading
      # a partial sidecar as authoritative made `sig-gen --write` on redmine report 5.9x more
      # `call.undefined-method` than the same project with no `sig/` at all.
      #
      # Memoised per loader: one pass over `class_decls` (~1-2k entries), and every consumer is a check
      # rule on the analysis hot path. Attribution is by buffer NAME, which survives the ADR-54 environment
      # cache since #725 — an environment blob written before that carries the `<cached>` sentinel instead,
      # which lands every class outside this set and leaves the pre-#735 behaviour, never a new silence.
      def project_declared_classes
        @state[:project_declared_classes] ||= build_project_declared_classes
      end

      def build_project_declared_classes
        environment = env
        return Set.new.freeze if environment.nil?

        project_files = self.class.project_sig_files(@signature_paths)
        return Set.new.freeze if project_files.empty?

        names = environment.class_decls.each_with_object(Set.new) do |(rbs_name, entry), acc|
          acc << rbs_name.to_s.delete_prefix("::") if self.class.project_entry?(entry, project_files)
        end
        names.freeze
      rescue ::RBS::BaseError
        Set.new.freeze
      end
      private :build_project_declared_classes

      # True when `class_name`'s RBS declaration is one the project wrote (see {#project_declared_classes}).
      def project_declared_class?(class_name)
        project_declared_classes.include?(class_name.to_s.delete_prefix("::"))
      end

      # The total RBS-environment build failure captured this run, or nil when the env built. Unlike
      # {#quarantined_signatures} — which the env survives, one file lighter, and which is re-derived by
      # re-parsing so a cache HIT reports it too — a total failure (typically `RBS::DuplicatedDeclarationError`:
      # a `signature_paths:` entry redeclaring a constant/class Rigor's bundled RBS already ships) collapses the
      # WHOLE env to nil. A failed build produces no cached success to hide behind (nothing is persisted, so
      # every run re-attempts and re-raises), so this is captured directly in {#env}'s rescue rather than
      # re-derived. Forcing `env` (any query does) populates it.
      #
      # @return [Array(String, String, Array<String>), nil] `[error_class_name, first_error_line,
      #   conflicting_buffer_names]`, or nil when the environment built successfully.
      def env_build_failure
        env unless @state[:env_loaded]
        @state[:env_build_failure]
      end

      # Issue #696 — the PER-CLASS sibling of {#env_build_failure}, one tier quieter in consequence: an
      # `RBS::DefinitionBuilder` failure ({#build_instance_definition} / {#build_singleton_definition}'s
      # rescue) leaves the class KNOWN but with no method surface, so every call on it — real methods and
      # typos alike — reads `Dynamic[top]` and stops being checkable. `class_known?` consults
      # {#known_class_names_set}, never a definition build, so nothing downstream can tell the difference.
      #
      # NOT forced the way {#env_build_failure} forces `env`, and it MUST NOT be: definition builds are lazy
      # (ADR-54 WD1 — per class, on first demand), so this answers "which classes has THIS loader failed to
      # build so far". A reader that forces would have to build every known class, which is a different and
      # far more expensive question than the run asked. The consequence for callers is a timing contract: a
      # snapshot taken before the per-file loop reads empty. `Runner::PoolCoordinator` reads it after.
      #
      # Recorded, not derived. The two conditions this sits beside are re-derivable from the built env
      # ({#quarantined_signatures} re-parses; {#virtual_rbs_collision_quarantined} inspects buffers), but a
      # definition-build failure leaves no trace in the env at all — the env is fine; it is the BUILD over it
      # that raised — so the rescue is the only place that ever knows.
      #
      # @return [Array<Array(String, String, String, Array<String>)>] `[class_name, error_class_name,
      #   first_error_line, conflicting_buffer_names]`, one per class, in first-failure order. Empty for a
      #   healthy sig set, which is the common case.
      def definition_build_failures
        (@state[:definition_build_failures] || []).dup.freeze
      end

      # Virtual (inline-synthesized) contributions dropped by the collision quarantine
      # ({.resolve_quarantining_virtual_collisions}): buffer names absent from the built env even though the
      # entry's content is non-empty and parses (a parse failure is the synthesizer's own WD6 skip, reported
      # through the synthesis reporter instead). Derived from the env rather than recorded during build —
      # the {#quarantined_signatures} trick — so a cache HIT, which never runs the build, reports the same
      # condition: the marshalled env simply lacks the dropped buffers.
      #
      # @return [Array<String>] virtual buffer names (source-file paths) whose contribution was dropped.
      def virtual_rbs_collision_quarantined
        @state[:virtual_rbs_collisions] ||= begin
          built = @state[:env]
          if built.nil? || @virtual_rbs.empty?
            [].freeze
          else
            present = built.buffers.to_set(&:name)
            @virtual_rbs.filter_map do |name, content|
              name if !content.empty? && !present.include?(name) && self.class.parseable_rbs?(content)
            end.freeze
          end
        end
      end

      # The referenced-but-undeclared types {.stub_missing_referenced_types} stubbed so the project classes
      # that mention them could build (e.g. an unavailable `DRb::DRbServer`, or a stale
      # `Textbringer::EditorError`). Recovered off the built env like {#synthesized_namespaces}, so it
      # survives the marshalled-env cache.
      #
      # Class / module stubs only — the `interface` and `type` stubs {.stub_declaration_for} also emits live in
      # `interface_decls` / `type_alias_decls`, not `class_decls`. That is deliberate: this list exists to feed
      # {#synthesized_type_names}, whose consumers key on a nominal receiver's class name, and both of those
      # kinds already read as untyped through {Inference::RbsTypeTranslator}.
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

      # Yields every type-alias declaration loaded into the environment (`type foo = ...`).
      # Yields `(RBS::TypeName, RBS::Environment::TypeAliasEntry)` pairs.
      def each_type_alias_decl
        return enum_for(:each_type_alias_decl) unless block_given?
        return unless env

        env.type_alias_decls.each do |type_name, decl_entry|
          yield [type_name, decl_entry]
        end
      end

      # ADR-20 slice 2e — iterates over every `%a{...}` annotation attached to a class- or module-level
      # declaration in the loaded RBS environment, yielding `(annotation_string, source_location)` pairs.
      #
      # Declarations come from {.entry_declarations}, NOT from a direct `entry.each_decl`: that accessor is
      # RBS 4.x-only, so the direct call raised `NoMethodError` on every RBS 3.x host — inside a rescue that
      # deliberately does not swallow `NoMethodError`. It stayed latent because nothing the `rbs-compat` job
      # runs reached an annotated declaration until #672 added a spec under `spec/rigor/environment` that
      # drives a whole `Runner`.
      # Used by {Rigor::Inference::HktRegistry.scan_rbs_loader} to find `rigor:v1:hkt_register` /
      # `rigor:v1:hkt_define` directives in user-authored overlays and merge them into the per-`Environment`
      # HKT registry. Yields nothing when the env failed to build (fail-soft, same shape as
      # {#each_known_class_name}).
      def each_class_decl_annotation
        return enum_for(:each_class_decl_annotation) unless block_given?
        return if env.nil?

        env.class_decls.each_value do |entry|
          self.class.entry_declarations(entry).each do |decl|
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
          self.class.entry_declarations(entry).each do |decl|
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
      #
      # Issue #696 — the report fires HERE, on the result, rather than in `build_*`'s rescue, and it fires on
      # a memo hit too. `#prewarm`'s cached producers walk every known class through this method, so by the
      # time a run demands `String` the nil is already memoised and the rescue will never run again; a report
      # wired to the rescue would say nothing. The guard keeps the cost on the hot path at one `@state` read,
      # and only on the nil branch — `nil` here is overwhelmingly an unknown class, not a failed build.
      def instance_definition(class_name)
        key = class_name.to_s
        definition =
          if @instance_definition_cache.key?(key)
            @instance_definition_cache[key]
          else
            @instance_definition_cache[key] = build_instance_definition(class_name)
          end
        report_definition_build_failure(class_name) if definition.nil? && @state[:definition_build_details]
        definition
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

        # Memoized per (name, args): the env is immutable for the loader's lifetime, so the expansion is a
        # pure function of the pair, and #529's translator wiring re-expands the same handful of aliases
        # (`Prism::node`, `int`, `string`, …) at every call site — the memo recoups most of that wall cost.
        memo = (@state[:type_alias_expansions] ||= {})
        key = [name, rbs_alias.args]
        return memo[key] if memo.key?(key)

        memo[key] = builder.expand_alias2(name, rbs_alias.args)
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
      #
      # The singleton twin of {#instance_definition}, reporting on the same terms (issue #696).
      def singleton_definition(class_name)
        key = class_name.to_s
        definition =
          if @singleton_definition_cache.key?(key)
            @singleton_definition_cache[key]
          else
            @singleton_definition_cache[key] = build_singleton_definition(class_name)
          end
        report_definition_build_failure(class_name) if definition.nil? && @state[:definition_build_details]
        definition
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

      # The ancestor chain of ONE class, as {RbsHierarchy} asks it to order two classes.
      #
      # Issue #696 review (second pass) — this used to live in the hierarchy, which branched on
      # `cache_store`: with a store it built the whole `RbsClassAncestorTable` and read one key, without a
      # store it demanded that one class. Three configurations, three different answers to "which classes
      # failed to build" for one project — 504 classes on a cold store, 0 on a warm one, 2 with no store —
      # and on the DEFAULT `--workers=0` path, where nothing pre-warms the store first, the cold answer was
      # the one written into the run-result cache and replayed on every warm run after it.
      #
      # The fix is {#during_internal_demand} on BOTH sides, not the removal of the branch. Collapsing to a
      # per-class demand everywhere was tried first and measured 50x slower on the warm path a cached run
      # actually takes (200 orderings: 0.0035s reading the table, 0.18s building 400 definitions), which is
      # the wrong trade for a determinism the marking already buys. What has to be identical across cache
      # states is the diagnostic, and with both sides marked neither contributes to it: the reported set is
      # the classes whose METHOD SURFACE the analysis demanded, in every configuration. The memo-hit report
      # in {#instance_definition} is what makes that hold — a class this path built and memoised as nil is
      # still reported when a real demand for it arrives later.
      #
      # The table side goes through {#ancestor_names_table}, the loader's own marked accessor, rather than
      # `Cache::RbsClassAncestorTable.fetch` directly. That direct fetch was the bypass: it walked every
      # known class through the public {#instance_definition} with nothing marking it.
      #
      # Answers are identical on both sides — the table's producer computes exactly this, keyed the same
      # way, and both yield `[]` for an unknown or unbuildable class. Pinned by spec across all three cache
      # states.
      #
      # @return [Array<String>] `::`-stripped ancestor names, or `[]` for an unknown or unbuildable class.
      def ancestor_names_for(class_name)
        key = class_name.to_s.delete_prefix("::")
        during_internal_demand do
          next ancestor_names_table.fetch(key, [].freeze) if cache_store

          definition = instance_definition(key)
          next [].freeze if definition.nil?

          definition.ancestors.ancestors.map { |ancestor| ancestor.name.to_s.delete_prefix("::") }.uniq.freeze
        end
      rescue ::RBS::BaseError, StandardError
        [].freeze
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
      #
      # Issue #696 — the whole body is a {#during_internal_demand}, not only the producers that happen to walk
      # definitions today. On a COLD store `RbsClassTypeParamNames.compute` and `RbsClassAncestorTable.compute`
      # ask {#instance_definition} for every known class; marking each producer covers that, and marking
      # `#prewarm` itself covers whichever producer grows the same appetite next.
      def prewarm
        return self if cache_store.nil?

        during_internal_demand do
          env
          known_class_names_set
          constant_type_table
          type_param_names_table
          ancestor_names_table
          instance_definitions_table
          singleton_definitions_table
        end
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

      # ADR-103 WD6 / #386 — yields `[class name, RBS::AST::Members::MethodDefinition]` for every method
      # member in the built environment that carries at least one annotation.
      #
      # The one reason this walk lives here rather than in its caller: `#env` is private, and it stays
      # private. The effect-envelope reader needs the *annotations* a gem's shipped signatures and
      # Rigor's bundled overlays declare — the accepted stratum of ADR-103 WD6, which discharges a call
      # site's taint because the same trust is already extended to those files' types — and nothing more
      # of the environment. Handing out the environment to get at them would trade a several-MB mutable
      # object for a read the loader can perform itself.
      #
      # Nested declarations are not descended into: `RBS::Environment` already flattens a nested
      # `class Foo::Bar` into its own `class_decls` entry, so a descent would key one member twice.
      #
      # Fail-soft, like every other query here: no environment (a build failure) yields nothing.
      def each_annotated_method_member
        environment = env
        return if environment.nil?

        environment.class_decls.each do |type_name, entry|
          class_name = type_name.to_s.sub(/\A::/, "")
          self.class.entry_declarations(entry).each do |decl|
            members = decl.respond_to?(:members) ? decl.members : nil
            next if members.nil?

            members.each do |member|
              next unless member.is_a?(::RBS::AST::Members::MethodDefinition)
              next if member.annotations.nil? || member.annotations.empty?

              yield class_name, member
            end
          end
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
          decls = self.class.entry_declarations(entry)
          next if decls.empty?
          next unless decls.all? { |decl| synthetic_decl?(decl, buffer_name) }

          type_name.to_s.sub(/\A::/, "")
        end
        names.sort_by { |name| name.count("::") }
      end

      # True when an AST declaration was emitted into `buffer_name` (one of the synthetic-source sentinels)
      # — identified by the buffer name on its location.
      def synthetic_decl?(decl, buffer_name)
        location = decl.respond_to?(:location) ? decl.location : nil
        location&.buffer&.name.to_s == buffer_name
      end

      def constant_type_table
        @constant_type_table ||= during_internal_demand do
          require_relative "../cache/rbs_constant_table"
          fetch_or_compute_producer(Cache::RbsConstantTable)
        end
      end

      def known_class_names_set
        @known_class_names_set ||= during_internal_demand do
          require_relative "../cache/rbs_known_class_names"
          fetch_or_compute_producer(Cache::RbsKnownClassNames)
        end
      end

      def type_param_names_table
        @type_param_names_table ||= during_internal_demand do
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
        @ancestor_names_table ||= during_internal_demand do
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
        warn_about_virtual_rbs_collisions
        @state[:env]
      rescue ::RBS::BaseError => e
        record_env_build_failure(e)
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

      # The collision twin of {#warn_about_quarantined_signatures}: name, once per run, the source files
      # whose inline-synthesized RBS was dropped because it collides with a declaration another signature
      # source already made ({.resolve_quarantining_virtual_collisions} — the explicit `.rbs` wins). Without
      # this the drop is silent, and "my `#:` annotation does nothing" has no visible cause. Reads the
      # derived {#virtual_rbs_collision_quarantined}, so a cache HIT warns identically.
      def warn_about_virtual_rbs_collisions
        return if @state[:virtual_collision_warned]

        dropped = virtual_rbs_collision_quarantined
        return if dropped.empty?

        @state[:virtual_collision_warned] = true
        listed = dropped.first(QUARANTINE_WARN_LIMIT)
        more = dropped.size - listed.size
        lines = listed.map { |name| "    - #{name}" }
        lines << "    … and #{more} more" if more.positive?
        warn(
          "rigor: dropped inline-RBS contribution(s) from #{dropped.size} file(s): they declare a
  " \
          "constant, alias, or global that another signature source (typically the project's own
  " \
          "`sig/`) already declares. The explicit `.rbs` declaration wins, so inline annotations in
  " \
          "these files do not bind. Remove the duplication from either side to restore them:
" \
          "#{lines.join("\n")}"
        )
      end

      # Records the total RBS-environment build failure captured in {#env}'s rescue so the analysis layer can
      # surface it as the `rbs.coverage.environment-build-failed` diagnostic (the twin of
      # {#quarantined_signatures}: quarantine keeps the env alive minus one file, a total failure collapses the
      # WHOLE env to nil, so every type-of query degrades to `Dynamic[top]` and most rules stop firing). Stored
      # as `[error_class_name, first_error_line, conflicting_buffer_names]`. The buffer names are lifted off a
      # `RBS::DuplicatedDeclarationError#decls` — the typical failure, a `signature_paths:` entry redeclaring a
      # constant/class Rigor's bundled RBS already ships — so the diagnostic can name the colliding files.
      def record_env_build_failure(error)
        first_line = error.message.to_s.lines.first.to_s.strip
        @state[:env_build_failure] = [error.class.name, first_line, env_build_conflict_buffers(error)].freeze
      end

      # The buffer (file) names carried by the colliding declarations of a `RBS::DuplicatedDeclarationError`, so
      # the diagnostic names the conflicting signature files rather than guessing. A buffer name is a `String`
      # path for a project `signature_paths:` file and a `Pathname` for a bundled RBS file, so each is coerced
      # to `String`. Other RBS build errors carry no `.decls`; they yield an empty list and the diagnostic
      # falls back to the message's first line alone.
      def env_build_conflict_buffers(error)
        return [].freeze unless error.respond_to?(:decls)

        error.decls.filter_map { |decl| decl.location&.buffer&.name }.map(&:to_s).uniq.freeze
      rescue ::RBS::BaseError, StandardError
        [].freeze
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
      #
      # {#during_internal_demand} (issue #696) — these two walk EVERY known class, so a failure they hit is a
      # failure of the sig set, not of anything the run asked about, and it must not reach
      # {#definition_build_failures}. The stderr banner is deliberately left armed here, byte-for-byte as
      # before.
      def instance_definitions_table
        @state[:instance_definitions_table] ||= during_internal_demand do
          build_definitions_table { |name| build_instance_definition(name) }
        end
      end

      def singleton_definitions_table
        @state[:singleton_definitions_table] ||= during_internal_demand do
          build_definitions_table { |name| build_singleton_definition(name) }
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
      rescue ::RBS::BaseError => e
        store_definition_build_detail(class_name, e)
        warn_about_definition_build_failure(class_name, e)
        nil
      end

      def build_singleton_definition(class_name)
        rbs_name = parse_type_name(class_name)
        return nil unless rbs_name
        return nil if env.nil?

        rbs_name = canonical_module_name(rbs_name)
        return nil unless env.class_decls.key?(rbs_name)

        builder.build_singleton(rbs_name)
      rescue ::RBS::BaseError => e
        store_definition_build_detail(class_name, e)
        warn_about_definition_build_failure(class_name, e)
        nil
      end

      # Issue #696 — the DETAIL half of the same rescue: what went wrong for this class, remembered so
      # {#definition_build_failures} can report it. Split from the REPORTING decision on purpose, and the
      # split is the whole fix.
      #
      # Recording in the rescue is wrong in both directions at once. Too loud: `#prewarm` and the cached
      # table producers walk EVERY known class, so on a cold store they enter this rescue for every class a
      # collision took down — 1,336 of them for one `class Object` duplicate — and the diagnostic named all
      # of them under `--workers=N` with a cold cache while naming 3 under every other configuration. Too
      # quiet: {#instance_definition} memoises the nil, so once that walk has run, the FIRST real demand
      # never re-enters the rescue and would record nothing at all.
      #
      # So the rescue only remembers, keyed by the `::`-stripped name (the eager walk spells it `::Acme`,
      # a dispatch site spells it `Acme`, and they are one class — the {#synthesized_namespaces}
      # convention), and {#report_definition_build_failure} decides. First writer wins: the instance and
      # singleton sides fail for the same underlying collision, and the first is the one a caller hit.
      def store_definition_build_detail(class_name, error)
        key = class_name.to_s.delete_prefix("::")
        details = (@state[:definition_build_details] ||= {})
        return if details.key?(key)

        details[key] = [key, error.class.name.to_s, definition_build_member(error),
                        definition_build_conflict_buffers(error)].freeze
      end

      # Issue #696 — the REPORTING half: promote a remembered detail into {#definition_build_failures}
      # because something the run was actually doing asked for this class's definition and got nothing.
      #
      # Called from {#instance_definition} / {#singleton_definition} — the demand entries — rather than from
      # the rescue, so it fires on a MEMO HIT too. That is what survives a pre-warm: the walk builds the
      # definition, fails, memoises nil, and never enters the rescue again, but the next real demand still
      # reads nil here and still reports. Reporting from the rescue could only ever see the first build.
      #
      # Silent inside a whole-universe walk ({#during_internal_demand}): a producer that touches every known
      # class is asking a question the RUN did not ask, and letting it contribute makes the reported class
      # list depend on whether a cache was cold — the same project saying different things under
      # `--workers=N` than under `--workers=0`, which is the defect this diagnostic exists to end.
      def report_definition_build_failure(class_name)
        return if @state[:internal_demand]

        details = @state[:definition_build_details]
        return if details.nil?

        key = class_name.to_s.delete_prefix("::")
        detail = details[key]
        return if detail.nil?

        reported = (@state[:definition_build_reported] ||= {})
        return if reported[key]

        reported[key] = true
        (@state[:definition_build_failures] ||= []) << detail
      end

      # Marks a definition demand that is RIGOR'S OWN, not the analysed program's, so
      # {#report_definition_build_failure} stays silent for the duration.
      #
      # The diagnostic reports classes whose METHOD SURFACE the analysis asked to resolve — that is what its
      # message promises, and it is the only demand set that does not vary with how the run was invoked. Two
      # kinds of demand are Rigor's own and must be excluded:
      #
      # - a whole-universe cache producer ({#prewarm}'s tables), which asks about every known class;
      # - the hierarchy oracle's ancestry lookup ({#ancestor_names_for}), which asks whether two classes are
      #   ordered, not whether either one's methods resolve.
      #
      # Both were cache-state-dependent before this, and each produced a DIFFERENT class list per
      # configuration for the same project — the second one on the DEFAULT `--workers=0` path (issue #696
      # review, second pass).
      #
      # Save-and-restore rather than a bare flag: `#prewarm` wraps a body whose members wrap themselves, and
      # a nested demand must not un-mark its caller on the way out.
      #
      # Per LOADER, not per thread. Nesting and a raise mid-demand are both handled, and the fork pool forks
      # after `#prewarm` returns, so no CLI path shares a loader across concurrent analyses. An in-process
      # host that did (`language_server/debouncer.rb` runs analysis on a `Thread`) could have one analysis
      # silence another's reporting; not reachable today, and not worth a thread-local until it is.
      def during_internal_demand
        previous = @state[:internal_demand]
        @state[:internal_demand] = true
        yield
      ensure
        @state[:internal_demand] = previous
      end

      # The third twin of {#warn_about_quarantined_signatures} / {#warn_about_virtual_rbs_collisions}: name,
      # once per class per PROCESS, a `RBS::DefinitionBuilder` failure caught in
      # {#build_instance_definition} / {#build_singleton_definition}'s rescue. Without it, `class_known?`
      # stays true (it only consults {#known_class_names_set}, never a definition build), so every call on
      # the class — real methods and typos alike — silently degrades to `Dynamic[top]`.
      #
      # STRUCTURAL DIVERGENCE from its two siblings: they fire from the single central site at the end of
      # {#env}, because the whole env is built eagerly and every quarantine/collision is already known by
      # then. Definition builds are LAZY (ADR-54 WD1 — built on demand per class the FIRST time a caller asks,
      # long after {#env} has already run), so there is no later central checkpoint to fire from before the
      # affected classes even exist. This warns inline at the rescue site instead, gated on
      # `@state[:definition_build_warned]` (keyed by class name) so the instance and singleton sides — and
      # any re-entry once the per-process `@instance_definition_cache` / `@singleton_definition_cache`
      # memoize the failure — warn at most once per class name, cache-hit runs included (a definition build
      # is per-process regardless of the RBS-env cache tier). `@state` is per-LOADER-INSTANCE, not
      # process-global, so under the fork-based analysis pool each worker holds its own loader and its own
      # `@state`: a class whose definition fails can print its warning once per worker that happens to touch
      # it, i.e. more than once in a single `rigor check` run. Deduplicating that across processes is out of
      # scope here — see [#295](https://github.com/rigortype/rigor/issues/295).
      def warn_about_definition_build_failure(class_name, error)
        warned = (@state[:definition_build_warned] ||= {})
        key = class_name.to_s
        return if warned[key]

        warned[key] = true
        first_line = error.message.to_s.lines.first.to_s.strip
        buffers = definition_build_conflict_buffers(error)
        collisions =
          if buffers.empty?
            ""
          else
            listed = buffers.first(QUARANTINE_WARN_LIMIT)
            more = buffers.size - listed.size
            lines = listed.map { |name| "    - #{name}" }
            lines << "    … and #{more} more" if more.positive?
            "\n  Colliding declaration(s):\n#{lines.join("\n")}"
          end
        warn(
          "rigor: RBS definition build failed for `#{class_name}`: #{error.class}: #{first_line}\n  " \
          "Rigor still treats the class as known, so calls into it now silently degrade to\n  " \
          "`Dynamic[top]` — real methods and typos alike — instead of resolving normally.#{collisions}"
        )
      end

      # The definition-build twin of {#env_build_conflict_buffers}: the declaration source file(s) named by a
      # `RBS::DefinitionBuilder` failure, so {#warn_about_definition_build_failure} can name the colliding
      # declarations rather than only the exception's class and message. The payload shape varies by error
      # class (`references/rbs`'s `lib/rbs/errors.rb`): `DuplicatedMethodDefinitionError` and
      # `InvalidOverloadMethodError` carry `#members` (each with a `#location`);
      # `DuplicatedInterfaceMethodDefinitionError` carries a single `#member`; most others
      # (`NoSuperclassFoundError`, `UnknownMethodAliasError`, `RecursiveAncestorError`, …) carry only a bare
      # `#location`. Falls back to an empty list — the warning still names the class and the exception's own
      # message — for the remainder (e.g. `SuperclassMismatchError`, which carries neither).
      def definition_build_conflict_buffers(error)
        definition_build_error_locations(error)
          .compact.filter_map { |loc| loc.buffer&.name }.map(&:to_s)
          .reject { |name| name == CACHED_LOCATION_BUFFER_NAME }.uniq.freeze
      rescue ::RBS::BaseError, StandardError
        [].freeze
      end

      # The `RBS::Location`s an error carries, by whichever accessor its class happens to expose (see the
      # shape survey above). Split out so the buffer-name extraction reads as one pipeline.
      def definition_build_error_locations(error)
        return Array(error.members).map(&:location) if error.respond_to?(:members) && error.members
        return [error.member.location] if error.respond_to?(:member) && error.member
        return [error.location] if error.respond_to?(:location)

        []
      end

      # The member the failure is ABOUT, taken off the error object rather than parsed out of its message.
      #
      # Issue #696 — the message cannot serve here. It is built from `RBS::Location`s, and the ADR-54 env
      # cache drops their POSITIONS, so a warm run's message would name no line and the same project would
      # report different text cold and warm. These accessors are `RBS::TypeName`s and Symbols, so they
      # survive the marshal round trip unchanged — and they name the class that actually CARRIES the
      # duplicate, which the failed-class list does not: a collision on `::Object#blank?` fails `String`,
      # `Integer` and `Array`, none of which is where the fix goes. (The buffer NAME does survive, since the
      # second review pass; it is the file list that uses it, not this.)
      #
      # Shapes vary by error class (`references/rbs`'s `lib/rbs/errors.rb`): the two duplicated-definition
      # errors expose `#qualified_method_name` directly; `InvalidOverloadMethodError` has `#type_name` +
      # `#method_name`; `UnknownMethodAliasError` and `NoSuperclassFoundError` have `#type_name`;
      # `SuperclassMismatchError` has `#name`. `RecursiveAncestorError` has none of them and yields nil, and
      # the diagnostic then omits the clause rather than inventing one.
      #
      # @return [String, nil]
      def definition_build_member(error)
        return error.qualified_method_name.to_s if error.respond_to?(:qualified_method_name)

        type_name = error.respond_to?(:type_name) ? error.type_name : nil
        type_name ||= error.respond_to?(:name) ? error.name : nil
        return nil if type_name.nil?

        method_name = error.respond_to?(:method_name) ? error.method_name : nil
        method_name.nil? ? type_name.to_s : "#{type_name}##{method_name}"
      rescue ::RBS::BaseError, StandardError
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
  end
end
