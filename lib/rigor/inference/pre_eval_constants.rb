# frozen_string_literal: true

require "prism"

require_relative "../scope"
require_relative "../type"
require_relative "scope_indexer"

module Rigor
  module Inference
    # Issue #352 / [ADR-17](../../../docs/adr/17-monkey-patch-pre-evaluation.md) — the constant half of the
    # `pre_eval:` publication surface.
    #
    # ADR-17 slice 2 gave `pre_eval:` a project-wide **method** registry ({ProjectPatchedMethods}). A
    # constant declared in the same file stayed invisible across the file boundary: `Scope#in_source_constants`
    # is per-file and is deliberately not part of `Runner#project_scope_seed_tables`, so only class-shaped
    # constants (a `class` / `module` declaration, or one of the four meta-new forms `ScopeIndexer`'s
    # `record_class_new_constant_decl` promotes) ever crossed. `TIMEOUT = 30` in a listed file read as
    # `Dynamic[top]` everywhere else.
    #
    # This collector closes that half. It walks the `pre_eval:` files with the SAME constant pre-pass the
    # per-file path uses ({ScopeIndexer.build_in_source_constants}) and publishes the result — widened — into
    # the project seed. Files not listed under `pre_eval:` are untouched, so the feature is opt-in by
    # construction and its cost stays proportional to the listed file count (ADR-17 WD1's cost-bounded
    # argument, which is also why slice 5's full-project two-pass stayed rejectable).
    #
    # ## The widening rule — why the published type is not the same-file type
    #
    # Same-file constant propagation is **value-pinned**: `42`, `"hello"`, a `Tuple`, a `HashShape`. Carrying
    # that verbatim across a file boundary would land diagnostics in files whose author never opened the
    # constant's definition — `CONFIG = { a: 1 }` arriving as a closed `HashShape` makes `CONFIG.fetch(:b)`
    # fire, `ARR = [1, 2]` arriving as a `Tuple` routes through `ShapeDispatch` instead of the RBS overload a
    # call site relied on. Today's cross-file `Dynamic[top]` is false-positive-free *by construction*, so
    # precision here can only spend that budget; AGENTS.md § "Implementation Guidelines" ranks false positives
    # above worst-case static reading, so this slice spends as little of it as possible.
    #
    # {.widen} therefore publishes the **erased class**, never the value:
    #
    # | Declared | Same file | Published cross-file |
    # | --- | --- | --- |
    # | `INT_LIT = 42` | `42` | `Integer` |
    # | `STR_LIT = "hello"` | `"hello"` | `String` |
    # | `ARR_LIT = [1, 2]` | `[1, 2]` (Tuple) | `Array` (raw, elements dropped) |
    # | `HSH_LIT = { a: 1 }` | `{ a: 1 }` (HashShape) | `Hash` (raw, keys dropped) |
    # | `ALIAS_CLS = String` | `singleton(String)` | `singleton(String)` |
    # | `Nest::NESTED_INT = 7` | `7` | `Integer` |
    #
    # Anything the rule does not recognise **declines** — the name is simply not published and reads exactly
    # as it does today. Declining is always the safe answer here, which is why the `else` arm is `nil` rather
    # than a fallback. `Constant[nil]` declines on purpose: a `X = nil` at declaration position is a
    # placeholder for a value assigned at runtime far more often than it is a genuine `NilClass`, and
    # publishing `NilClass` project-wide would make every use of it a diagnostic.
    #
    # Value-pinning a *provably* frozen single-write literal cross-file is a strictly later question; it needs
    # its own FP measurement and is deliberately not attempted here.
    #
    # **Issue #644 asked that later question and answered it.** The discovery pre-pass now publishes a
    # project-wide table of syntactic frozen-scalar literal assignments (Symbol / Integer / Float / boolean,
    # written once, in one file), with the FP measurement this paragraph asked for. Where that table and this
    # one both answer a name, THAT TABLE WINS and the value is not erased — a listed `TIMEOUT = 30` reads
    # `30`, not `Integer`. Nothing above is wrong; its scope is narrower than it reads. The widening exists
    # for the rvalues whose basis this collector cannot fully see, and every hazard it names — the closed
    # `HashShape`, the `Tuple` displacing an RBS overload, the mutable String — is a form #644's table
    # DECLINES. So the two producers do not overlap where the widening earns its cost, and where they do
    # overlap the narrower, purely syntactic basis is the better-founded answer. Normative in
    # `docs/internal-spec/inference-engine.md` § "Cross-file value constants"; pinned by
    # `spec/rigor/analysis/pre_eval_constants_spec.rb`.
    #
    # What this collector still owns alone: every rvalue #644 declines — a String, an Array, a Hash, a class
    # alias, and anything that needs the rvalue TYPED rather than read off the syntax.
    #
    # ## The multi-file write rule — widen on conflict, all the way to `Dynamic[top]`
    #
    # Within one file, `ScopeIndexer#record_constant_write` unions repeated writes; that union is widened as a
    # whole (`X = 1; X = "a"` in one file publishes `Integer | String`). ACROSS files the same union would be
    # a type neither author can see, so the rule is **widen on conflict**: when two listed files publish the
    # same qualified name with different widened types, the name is dropped from the table entirely and reads
    # as `Dynamic[top]` — the widest type there is, and the one the name already had. Agreeing writes (`X = 1`
    # here, `X = 2` there — both `Integer`) are not a conflict at all, which is the point of widening first:
    # `1 | 2` is never produced.
    #
    # ## Ordering
    #
    # The published table seeds `Scope#in_source_constants`, which `Reflection.constant_type_at` consults
    # AFTER the class registry and `discovered_classes`. A published entry can therefore never mask a
    # class-shaped constant that already crossed, and the per-file table always wins over the seed (see
    # {ScopeIndexer.index}'s merge) — same-file remains the most specific authority.
    module PreEvalConstants
      EMPTY = {}.freeze

      module_function

      # Collects and widens the constants every `pre_eval:` file declares.
      #
      # @param paths [Array<String>] absolute paths to the `pre_eval:` files that exist on disk.
      # @param scope_builder [#call] `path -> Rigor::Scope`; the caller supplies a project-seeded, environment-
      #   bound scope so the rvalue typer resolves cross-file classes exactly as per-file analysis would.
      # @param target_ruby [String, nil] the Prism parse version (`Configuration#target_ruby`).
      # @param buffer [Rigor::Analysis::BufferBinding, nil] editor-mode binding; when set, a listed file that
      #   matches the in-flight buffer is read from its physical bytes.
      # @return [Hash{String => Rigor::Type}] frozen qualified-name -> published type table.
      def collect(paths:, scope_builder:, target_ruby: nil, buffer: nil)
        published = {}
        conflicted = {}
        paths.each do |path|
          file_constants(path, scope_builder: scope_builder, target_ruby: target_ruby, buffer: buffer)
            .each { |name, type| merge_publication(published, conflicted, name, type) }
        end
        published.freeze
      end

      # Folds one declaration into the accumulator under the widen-on-conflict rule. A name that has already
      # conflicted stays out for the rest of the collection — a later agreeing write must not resurrect it.
      def merge_publication(published, conflicted, name, type)
        return if conflicted.key?(name)

        widened = widen(type)
        return if widened.nil?

        existing = published[name]
        return published[name] = widened if existing.nil?
        return if existing == widened

        published.delete(name)
        conflicted[name] = true
      end
      private_class_method :merge_publication

      # The per-file constant table, typed through the same pre-pass the per-file path runs. Deliberately NOT
      # a full `ScopeIndexer.index`: ADR-17 WD4 keeps the pre-eval pass a discovery walk, and the constant
      # pre-pass (plus the declaration artifacts it needs to resolve in-file class references) is exactly the
      # discovery facet this feature consumes. Fails soft to the empty table — a pre-eval file that cannot be
      # read or parsed already surfaces a `pre-eval.parse-error` warning from {ProjectPatchedScanner}, and it
      # must never break the run.
      def file_constants(path, scope_builder:, target_ruby: nil, buffer: nil)
        physical = buffer ? buffer.resolve(path) : path
        parse_result = Prism.parse(File.read(physical), filepath: path, version: target_ruby)
        return EMPTY unless parse_result.errors.empty?

        root = parse_result.value
        ScopeIndexer.build_in_source_constants(root, declaration_seeded_scope(root, scope_builder.call(path)))
      rescue StandardError
        EMPTY
      end
      private_class_method :file_constants

      # Mirrors the head of {ScopeIndexer.index}: seed the file's own declaration overrides and discovered
      # classes onto the project-seeded scope so a `CONST = SomeClassDefinedRightHere.new` rvalue types the
      # same way it does during real analysis.
      def declaration_seeded_scope(root, scope)
        declared_types, discovered_classes = ScopeIndexer.build_declaration_artifacts(root)
        scope.with_discovery(
          scope.discovery.with(
            declared_types: declared_types,
            discovered_classes: scope.discovered_classes.merge(discovered_classes)
          )
        )
      end
      private_class_method :declaration_seeded_scope

      # The publication widening. Returns the type to publish, or `nil` to decline (the name keeps today's
      # `Dynamic[top]` cross-file reading). See the module doc for why declining is the safe default.
      def widen(type)
        case type
        when Type::Constant then widen_constant(type)
        when Type::Refined then widen(type.base)
        when Type::IntegerRange then Type::Combinator.nominal_of("Integer")
        when Type::Tuple then Type::Combinator.nominal_of("Array")
        when Type::HashShape then Type::Combinator.nominal_of("Hash")
        when Type::Nominal then type.type_args.empty? ? type : Type::Combinator.nominal_of(type.class_name)
        when Type::Singleton then type
        when Type::DataInstance, Type::StructInstance then nominal_for_class_name(type.class_name)
        when Type::Union then widen_union(type)
        end
      end

      # `Constant[v]` publishes `v`'s class. `nil` declines (see the module doc); so does a value whose class
      # is anonymous, which has no name to publish under.
      def widen_constant(type)
        return nil if type.value.nil?

        nominal_for_class_name(type.value.class.name)
      end
      private_class_method :widen_constant

      def nominal_for_class_name(class_name)
        return nil unless class_name.is_a?(String) && !class_name.empty?

        Type::Combinator.nominal_of(class_name)
      end
      private_class_method :nominal_for_class_name

      # A union publishes only when EVERY member widens: one unrecognised arm means the union's real extent is
      # unknown, and a partial union would be narrower than the truth — the false-positive direction.
      def widen_union(type)
        widened = type.members.map { |member| widen(member) }
        return nil if widened.any?(&:nil?)

        Type::Combinator.union(*widened)
      end
      private_class_method :widen_union
    end
  end
end
