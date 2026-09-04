# frozen_string_literal: true

require "prism"

require_relative "../configuration"
require_relative "../environment"
require_relative "../scope"
require_relative "../reflection"
require_relative "../type"
require_relative "../source/literals"
require_relative "../source/node_children"
require_relative "../inference/def_return_typer"
require_relative "../inference/scope_indexer"
require_relative "../inference/rbs_type_translator"
require_relative "meta_class_shape"
require_relative "rbs_validity"

module Rigor
  module SigGen
    # Core generator for `rigor sig-gen` (ADR-14 slice 1 — MVP).
    #
    # Walks every `.rb` file under the input paths, builds a per-node scope index via
    # {Rigor::Inference::ScopeIndexer}, finds every `Prism::DefNode` whose enclosing class is nameable, types the
    # body's last expression to derive an inferred return, looks up the project's existing RBS declaration (if
    # any), and emits one {MethodCandidate} per def.
    #
    # The MVP keeps the scope deliberately narrow:
    # - Only instance methods inside a `class` / `module` body are considered. Top-level / DSL-block / singleton
    #   defs are skipped (`sig.skipped.complex-shape`).
    # - Parameter signatures are hard-coded to `untyped` per ADR-14 § "Robustness principle compliance" clause 2;
    #   `--params=observed` arrives in slice 3.
    # - Optional / rest / keyword / block params disqualify the def (`sig.skipped.complex-shape`).
    # - A `Dynamic[top]` inferred return becomes `sig.skipped.untyped-return` — emitting `untyped` would obscure
    #   rather than help.
    # - Tighter-return detection compares the RBS-erased spellings only when the existing declared return
    #   strictly accepts the inferred one (acceptance check under the engine's current `:gradual` mode; ADR-14
    #   reserves the eventual `:strict` mode).
    class Generator # rubocop:disable Metrics/ClassLength
      # Methods the generator rendered into RBS that `rbs` itself rejects. Populated by {#build_candidate}; each
      # one is a Rigor rendering DEFECT, not a property of the user's code, so the CLI reports them as such.
      UnrenderableMethod = Data.define(:path, :class_name, :method_name, :rbs, :error)

      # @return [Array<UnrenderableMethod>] empty on a healthy run; read after {#run}.
      attr_reader :unrenderable, :unresolvable_superclasses

      # @param configuration [Rigor::Configuration]
      # @param paths [Array<String>] files / directories to scan.
      # @param observations [Hash{[String, Symbol] => Array<Array<Rigor::Type>>}]
      #   ADR-14 slice 3 — per-target-method arg-tuple observations
      #   produced by {ObservationCollector}. An empty Hash (the default)
      #   means "no observations available; emit `untyped` for every
      #   parameter position" per ADR-5 clause 2.
      def initialize(configuration:, paths:, observations: {}, include_private: false)
        @configuration = configuration
        @paths = paths
        @observations = normalize_observations(observations)
        @include_private = include_private
        # Per-file scratch state. `analyse_file` resets each one to a fresh container for every file walked so
        # candidates from one file don't leak into another; initialising empty here gives downstream consumers
        # (`build_candidate`, `method_def_prefix`) a never-nil invariant without per-call-site defensive guards.
        @namespace_kinds = {}
        @module_function_methods = Set.new
        @class_shells = Set.new
        @class_superclasses = {}
        @meta_layouts = {}
        # Whole-run, NOT per-file: a rendering defect is reported once at the end of the run.
        @unrenderable = []
        # Issue #735 — whole-run too: `{ class name => the superclass token that resolves nowhere }`.
        @unresolvable_superclasses = {}
        # Issue #722 — whole-run: `{ class name => the lexical nesting its header is written in }`.
        @superclass_nestings = {}
      end

      # Lifts legacy plain-`Array[Type]` observation entries into {ObservedCall} carriers. Specs from the
      # slice-3 generation predate the carrier and pass observations as `{ [class, method] => [[type1, type2],
      # ...] }`; the wrapper keeps those passing while internal code always sees the new shape.
      def normalize_observations(map)
        return map if map.empty?

        map.transform_values { |entries| entries.map { |entry| ObservedCall.from(entry) } }
      end

      # @return [Array<MethodCandidate>]
      def run
        @environment = build_environment
        resolved = resolve_paths(@paths)
        candidates = resolved.flat_map { |path| analyse_file(path, @environment) }
        demote_overridden_base_methods(
          demote_unresolvable_superclasses(resolve_superclass_spellings(candidates))
        )
      end

      private

      # Issue #744 — a base class's method is NOT emitted when a project subclass overrides it and the
      # override is not emitted itself.
      #
      # RBS resolves an undeclared subclass method through its ancestors, so a precise return written for
      # the base becomes the subclass's answer. redmine's `FieldFormat::Base#target_class` honestly returns
      # `nil`; `RecordList#target_class` overrides it with a real lookup that sig-gen could not type, and
      # the emitted `def target_class: () -> nil` then produced four `undefined method … for nil` on the
      # subclass's own working code, plus a `def.return-type-mismatch` telling the user their correct
      # override was wrong.
      #
      # Emitting nothing puts both classes back on source inference, which answers correctly for each. The
      # base keeps its signature whenever nothing overrides the method, and whenever the override IS
      # emitted with a type of its own — the declaration is only dangerous when it is the only one.
      #
      # Whether an inherited declaration SHOULD outrank a class's own source `def` is a separate question
      # (#744 half 2) and is not decided here: this pass only stops sig-gen manufacturing the conflict.
      def demote_overridden_base_methods(candidates)
        superclasses = candidates.each_with_object({}) do |candidate, acc|
          (candidate.class_superclasses || {}).each { |name, sup| acc[name] = sup.sub(/\[.*\]\z/, "") }
        end
        return candidates if superclasses.empty?

        overridden = unsigned_override_ancestors(candidates, superclasses)
        return candidates if overridden.empty?

        candidates.map do |candidate|
          next candidate unless Classification::EMITTABLE.include?(candidate.classification)
          next candidate unless overridden.include?([candidate.class_name, candidate.method_name])

          demoted_candidate(candidate, :overridden_by_unsigned_subclass)
        end
      end

      # `[class name, method name]` pairs an UNSIGNED override shadows: for every candidate that will not
      # be emitted, every ancestor of its class paired with its method name.
      def unsigned_override_ancestors(candidates, superclasses)
        candidates.each_with_object(Set.new) do |candidate, acc|
          next if Classification::EMITTABLE.include?(candidate.classification)
          next if candidate.class_name.nil?

          each_ancestor(candidate.class_name, superclasses) { |name| acc << [name, candidate.method_name] }
        end
      end

      def each_ancestor(class_name, superclasses)
        seen = {}
        current = class_name
        while (parent = superclasses[current]) && !seen[parent]
          seen[parent] = true
          yield parent
          current = parent
        end
      end

      def demoted_candidate(candidate, reason)
        MethodCandidate.new(
          path: candidate.path, class_name: candidate.class_name, method_name: candidate.method_name,
          kind: candidate.kind, classification: Classification::SKIPPED, skip_reason: reason,
          inferred_return: candidate.inferred_return, declared_return_rbs: candidate.declared_return_rbs,
          namespace_kinds: candidate.namespace_kinds, class_shells: candidate.class_shells,
          class_superclasses: candidate.class_superclasses
        )
      end

      # Issue #722 — resolves each recorded superclass token to the class Ruby means by it, and rewrites the
      # emitted spelling when the two differ.
      #
      # `record_superclass` kept the source token verbatim on the reasoning that "RBS resolves it relative to
      # the emitted namespace, matching Ruby's lexical scope". That holds only while the emitted namespace
      # equals the source nesting, and sig-gen FLATTENS: `module Admin; class Record2 < Record` is written
      # out as the compact `class Admin::Record2 < Record`, and RBS resolves a compact header's superclass at
      # the TOP level (verified against the rbs gem), so the emitted token silently re-points at `::Record`
      # where the program means `Admin::Record`. The checker resolves the same declaration correctly, so the
      # generated sidecar contradicted the analyzer that wrote it.
      #
      # Candidate order is Ruby's own for the superclass expression: the header's nesting innermost-first,
      # then the bare name — the reading `Scope#ancestor_name_candidates` owns for the analyzer's class
      # graph. The question here is about the EMITTED tree, so the "is this a class" test is this run's
      # declarations plus the RBS environment rather than the discovery tables; keep the two orders in step.
      def resolve_superclass_spellings(candidates)
        return candidates if @superclass_nestings.empty?

        known = candidates.each_with_object(Set.new) do |candidate, acc|
          acc << candidate.class_name if candidate.class_name
          acc.merge(candidate.class_shells || [])
        end
        rewrites = superclass_rewrites(known)
        return candidates if rewrites.empty?

        candidates.map do |candidate|
          overlap = rewrites.slice(*candidate.class_superclasses.keys)
          next candidate if overlap.empty?

          rebuild_with_superclasses(candidate, candidate.class_superclasses.merge(overlap))
        end
      end

      def superclass_rewrites(known)
        @superclass_nestings.each_with_object({}) do |(full, (nesting, token)), acc|
          next if token.nil? || nesting.empty?

          resolved = resolve_superclass_token(token, nesting, known)
          acc[full] = resolved if resolved && resolved != token
        end
      end

      # The first candidate spelling that names a class this run declares or the RBS environment knows, or
      # nil when none does — an unresolvable superclass is #735's business, not this pass's.
      def resolve_superclass_token(token, nesting, known)
        base = token.sub(/\[.*\]\z/, "")
        args = token[base.length..] || ""
        nesting.length.downto(1) do |i|
          candidate = "#{nesting[0, i].join('::')}::#{base}"
          return "#{candidate}#{args}" if known.include?(candidate) ||
                                          Reflection.rbs_class_known?(candidate, environment: @environment)
        end
        token
      end

      def rebuild_with_superclasses(candidate, superclasses)
        MethodCandidate.new(
          path: candidate.path, class_name: candidate.class_name, method_name: candidate.method_name,
          kind: candidate.kind, classification: candidate.classification,
          inferred_return: candidate.inferred_return, declared_return_rbs: candidate.declared_return_rbs,
          rbs: candidate.rbs, skip_reason: candidate.skip_reason,
          namespace_kinds: candidate.namespace_kinds, class_shells: candidate.class_shells,
          class_superclasses: superclasses
        )
      end

      # Issue #735 — a generated declaration whose superclass chain does not terminate in a class the RBS
      # environment knows is DROPPED rather than emitted.
      #
      # `record_superclass` is right that a subclass declaration must carry its superclass: without it the
      # sidecar misrepresents the class and dispatch degrades. But emitting one the environment cannot
      # resolve is worse than either — `RBS::NoSuperclassFoundError` collapses the class, so every call into
      # it reads `Dynamic[top]` and the whole declaration is a liability. On redmine, `class Principal <
      # ApplicationRecord` (nothing declares `ApplicationRecord`, and nothing could: the chain ends at
      # `ActiveRecord::Base`, which no RBS in the environment carries) collapsed 98 classes on the very next
      # run. A chain that LOOPS is dropped for the same reason, and is the shape that made an
      # `AncestorBuilder` walk recurse until `SystemStackError` (#609).
      #
      # Dropping is the conservative end: no declaration leaves the class exactly as it was before sig-gen
      # ran — source discovery and the plugins still type it. Emitting the class with the superclass merely
      # OMITTED would be the harmful middle: the class becomes RBS-known with only the emitted methods, so
      # every inherited call fires `call.undefined-method`.
      def demote_unresolvable_superclasses(candidates)
        superclasses = candidates.each_with_object({}) do |candidate, acc|
          (candidate.class_superclasses || {}).each { |name, sup| acc[name] = sup }
        end
        # Everything this run declares, superclass or not: a chain that reaches `class Record` — emitted
        # here, with no superclass of its own — terminates in a class the next run WILL know.
        emitted = candidates.each_with_object(Set.new) do |candidate, acc|
          acc << candidate.class_name if candidate.class_name
          acc.merge(candidate.class_shells || [])
        end
        unresolvable = superclasses.each_with_object({}) do |(name, _sup), acc|
          root = unresolved_superclass_root(name, superclasses, emitted)
          acc[name] = root if root
        end
        return candidates if unresolvable.empty?

        candidates.map do |candidate|
          owner = unresolvable_for(candidate.class_name, unresolvable)
          next candidate if owner.nil?

          record_unresolvable_superclass(candidate, owner)
        end
      end

      # A nested class or module goes with its wrapper. `WikiPage::Webhookable`'s declaration is emitted
      # INSIDE `class WikiPage < ApplicationRecord`, so keeping the inner one while dropping the outer emits
      # the unresolvable header anyway — the wrapper is not a candidate of its own and carries no methods,
      # so nothing else would have demoted it.
      def unresolvable_for(class_name, unresolvable)
        return nil if class_name.nil?
        return [class_name, unresolvable[class_name]] if unresolvable.key?(class_name)

        unresolvable.each do |name, root|
          return [name, root] if class_name.start_with?("#{name}::")
        end
        nil
      end

      # The first superclass token on `name`'s recorded chain that neither the RBS environment knows nor this
      # run emits, or nil when the chain terminates in a known class. A chain that revisits a class returns
      # that class's own superclass token — a cycle resolves nowhere.
      def unresolved_superclass_root(name, superclasses, emitted, seen = {})
        superclass = superclasses[name]
        return nil if superclass.nil?
        return superclass if seen[name]

        seen[name] = true
        # The recorded spelling may carry the type arguments {#generic_superclass_spelling} added; the
        # resolvability question is about the class, so it is asked of the bare name.
        base = superclass.sub(/\[.*\]\z/, "")
        return nil if Reflection.rbs_class_known?(base, environment: @environment)
        return superclass unless emitted.include?(base)

        unresolved_superclass_root(base, superclasses, emitted, seen)
      end

      def record_unresolvable_superclass(candidate, owner)
        class_name, root = owner
        @unresolvable_superclasses[class_name] ||= root
        MethodCandidate.new(
          path: candidate.path, class_name: candidate.class_name, method_name: candidate.method_name,
          kind: candidate.kind, classification: Classification::SKIPPED,
          skip_reason: :unresolvable_superclass, inferred_return: candidate.inferred_return,
          declared_return_rbs: candidate.declared_return_rbs,
          namespace_kinds: candidate.namespace_kinds, class_shells: candidate.class_shells,
          class_superclasses: candidate.class_superclasses
        )
      end

      def build_environment
        Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths
        )
      end

      def resolve_paths(args)
        args.flat_map do |arg|
          if File.directory?(arg)
            Dir.glob(File.join(arg, "**/*.rb"), sort: true)
          elsif File.file?(arg) && arg.end_with?(".rb")
            [arg]
          else
            []
          end
        end.uniq
      end

      def analyse_file(path, environment)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: @configuration.target_ruby)
        return [] if parse_result.errors.any?

        base_scope = Scope.empty(environment: environment)
        scope_index = Inference::ScopeIndexer.index(parse_result.value, default_scope: base_scope)

        @namespace_kinds = {}
        @module_function_methods = Set.new
        @class_shells = Set.new
        @class_superclasses = {}
        @meta_layouts = collect_meta_layouts(scope_index)
        register_meta_classes
        defs = collect_method_definitions(parse_result.value)
        # Candidate construction freezes the per-file maps above (see {#build_candidate}), so every registration
        # pass has to be finished before the first `build_candidate` call. Meta members lead the RETURNED order —
        # a value class's members and constructors read first, ahead of the methods its block body defines.
        meta_candidates = collect_meta_member_candidates(path, scope_index)
        candidates_from_defs = defs.filter_map do |def_node, class_name, kind|
          # An analyzer bug typing one def's body must cost only that def's candidate, never the whole
          # `rigor sig-gen` run. The `check` path recovers each *file* this way (worker_session.rb); sig-gen
          # recovers per-def so the rest of the file's candidates still emit.

          classify_def(path, def_node, class_name, kind, scope_index)
        rescue StandardError
          nil
        end
        obs_ivar_map = build_observed_ivar_map(parse_result.value)
        meta_candidates + candidates_from_defs +
          collect_attr_candidates(parse_result.value, path, scope_index, obs_ivar_map)
      end

      # Walks the AST collecting `(def_node, class_name, kind)` tuples for every `def` Rigor can re-type. Slice 1
      # covered instance `def foo` methods inside a nameable `class` / `module` body. Slice 4 extends this to
      # singleton-side methods via `def self.foo` and `class << self; def foo; end`; top-level / DSL-block defs
      # still degrade silently (no nameable receiver).
      #
      # ADR-14 gap-#3 follow-up tracks two extra pieces during the same walk so the Writer can emit kind-correct
      # RBS without guessing:
      #
      # - `@namespace_kinds[qualified_name]` records whether each segment came from `class Foo` (`:class`) or
      #   `module Foo` (`:module`). Used by the writer's `wrap_in_modules` step to emit the right keyword for
      #   each intermediate segment AND the leaf.
      # - `@module_function_methods` records `(class_name, method_name)` pairs where a `module_function` (no
      #   args) call preceded the `def` inside a module body. The renderer emits `def self?.name` for these, the
      #   RBS spelling that matches the dual instance + singleton dispatch the runtime produces.
      def collect_method_definitions(root)
        out = []
        walk_defs(root, [], false, false, out)
        out
      end

      def walk_defs(node, prefix, in_singleton_class, module_function_active, out)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          return if descend_into_namespace?(node, prefix, out)
        when Prism::SingletonClassNode
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_defs(node.body, prefix, true, false, out)
            return
          end
        when Prism::DefNode
          collect_def_node(node, prefix, in_singleton_class, module_function_active, out)
          return
        when Prism::ConstantWriteNode
          body = meta_block_body(node, prefix)
          if body
            walk_defs(body, prefix + [node.name.to_s], false, false, out)
            return
          end
        when Prism::StatementsNode
          walk_statements(node, prefix, in_singleton_class, module_function_active, out)
          return
        end

        node.rigor_each_child do |child|
          walk_defs(child, prefix, in_singleton_class, module_function_active, out)
        end
      end

      def descend_into_namespace?(node, prefix, out)
        name = qualified_constant_path(node.constant_path)
        return false unless name

        full = (prefix + [name]).join("::")
        @namespace_kinds[full] = node.is_a?(Prism::ClassNode) ? :class : :module
        record_superclass(node, full, prefix)
        walk_namespace_body(node, prefix + [name], out)
        true
      end

      # ADR-14: a generated subclass declaration MUST carry its superclass, or the sidecar `sig/` misrepresents
      # the class (inherited members vanish → receiver dispatch degrades to `Dynamic`) and, worse, a nested
      # reference to an inherited type re-declares the class as a bare namespace on the RBS side and can
      # collapse the whole env (the 2026-07-04 redmine `GitAdapter < AbstractAdapter` crash). Only a plain
      # constant superclass is emittable: `class X < Foo` / `class X < Foo::Bar` yields the source token verbatim
      # (RBS resolves it relative to the emitted namespace, matching Ruby's lexical scope). A computed
      # superclass (`Class.new`, any other `CallNode`) is left unrecorded — a `Data.define` / `Struct.new` one is
      # already carried by {#register_meta_classes}, and the rest are un-representable, where guessing would
      # misfold.
      def record_superclass(node, full, prefix)
        return unless node.is_a?(Prism::ClassNode)

        superclass = qualified_constant_path(node.superclass)
        return if superclass.nil?

        # Issue #722 — the nesting the header is WRITTEN in, kept whole-run (not per-file scratch) because
        # the name it resolves to may be a class another file declares. Resolved once every file has been
        # walked, in {#resolve_superclass_spellings}.
        spelling = generic_superclass_spelling(superclass)
        # The token rides along because `@class_superclasses` is per-FILE scratch, reset before the next
        # file, while this table is whole-run.
        @superclass_nestings[full] = [prefix.dup, spelling]
        @class_superclasses[full] = spelling
      end

      # Issue #735 — a GENERIC superclass has to be written with its arguments. `class Entries < Array`
      # yields `RBS::InvalidTypeApplicationError: ::Array expects parameters [unchecked out E], but given
      # args []`, which fails the build for that class exactly as an unresolvable superclass does — redmine
      # subclasses `Array` five times. The element type is not something this pass can infer, so it is
      # `untyped`: the subclass's OWN methods are what sig-gen is here to record, and `Array[untyped]` keeps
      # the inherited surface resolving instead of collapsing the class.
      def generic_superclass_spelling(superclass)
        loader = @environment&.rbs_loader
        return superclass if loader.nil?

        arity = loader.class_type_param_names(superclass).size
        return superclass if arity.zero?

        "#{superclass}[#{(['untyped'] * arity).join(', ')}]"
      rescue StandardError
        superclass
      end

      # The ADR-48 member layouts for this file, in one table keyed by qualified class name. Reading the engine's
      # own tables instead of re-recognising `Data.define` / `Struct.new` here is what keeps sig-gen's view of a
      # value class from drifting from the analyser's: the walker that populates them ({Inference::ScopeIndexer})
      # already covers the constant-assigned form (`Point = Data.define(:x, :y)`), the named-subclass form
      # (`class Point < Data.define(:x, :y)`), a `::Data` receiver, and the `keyword_init:` flag. sig-gen's earlier
      # private recogniser covered none of the last three and was the reason #227's output was wrong rather than
      # merely thin.
      MetaLayout = Data.define(:kind, :member_names, :keyword_init)
      private_constant :MetaLayout

      def collect_meta_layouts(scope_index)
        scope = scope_index.each_value.first
        return {} if scope.nil?

        layouts = {}
        scope.data_member_layouts.each do |name, members|
          layouts[name] = MetaLayout.new(kind: :data, member_names: members, keyword_init: false)
        end
        scope.struct_member_layouts.each do |name, layout|
          layouts[name] = MetaLayout.new(kind: :struct, member_names: layout[:members],
                                         keyword_init: layout[:keyword_init])
        end
        layouts
      end

      # ADR-14 gap-#3 (e): a `Const = Data.define(...)` / `Const = Struct.new(...)` assignment declares a class the
      # source never spells with a `class` keyword — the runtime stamps an anonymous class at the rvalue and binds
      # it to `Const` — so the generated RBS needs an explicit `class Const` of its own. Without it, references to
      # `Const` in a return type fail to resolve under Steep (the canonical case is
      # `GemResolver::Resolved | GemResolver::Unresolvable`, where `Unresolvable = Data.define(:gem_name, :reason)`).
      #
      # Every layout-carrying class therefore gets the `class` keyword in `@namespace_kinds` (so the leaf wins over
      # the intermediate-segment `module` default), its `::Data` / `::Struct[untyped]` ancestry, and a `@class_shells`
      # entry so the writer declares it even when every member candidate is suppressed as already-declared. The
      # named-subclass form is registered too: its `class` keyword is not in question, but its computed superclass
      # is exactly what {#record_superclass} refuses to guess at.
      def register_meta_classes
        @meta_layouts.each do |class_name, layout|
          @namespace_kinds[class_name] = :class
          @class_shells << class_name
          @class_superclasses[class_name] = MetaClassShape::SUPERCLASSES.fetch(layout.kind)
        end
      end

      # The `do ... end` body of a `Const = Data.define(...) do ... end` assignment, when `Const` carries a layout.
      # Defs inside that block bind on `Const`, NOT on the enclosing namespace — the runtime `class_eval`s the block
      # into the anonymous class it just stamped. Attributing them to the enclosing namespace is what made sig-gen
      # report `VoidOrigin#label` against `Rigor::Inference` and then, because a method-bearing leaf defaults to the
      # `class` keyword, redeclare that module as a class (#227).
      def meta_block_body(node, prefix)
        return nil unless node.value.is_a?(Prism::CallNode)
        return nil unless @meta_layouts.key?((prefix + [node.name.to_s]).join("::"))

        node.value.block&.body
      end

      # Module / class bodies are walked through the `walk_statements` path so `module_function` (no-args)
      # encountered as one statement applies to every subsequent sibling def in the same body. The directive is
      # module-scoped semantically — classes inherit `module_function` via `Module`'s ancestor chain but don't
      # honour it the same way at runtime, so tracking is only meaningful inside `ModuleNode` bodies. Generator
      # emits `def self?.name` for the marked defs.
      def walk_namespace_body(namespace_node, prefix, out)
        return if namespace_node.body.nil?

        walk_defs(namespace_node.body, prefix, false, false, out)
      end

      def walk_statements(stmts_node, prefix, in_singleton_class, module_function_active, out)
        stmts_node.body.each do |stmt|
          if module_function_directive?(stmt)
            module_function_active = true
            next
          end
          walk_defs(stmt, prefix, in_singleton_class, module_function_active, out)
        end
      end

      def module_function_directive?(node)
        return false unless node.is_a?(Prism::CallNode)
        return false unless node.name == :module_function && node.receiver.nil?

        (node.arguments&.arguments || []).empty?
      end

      def collect_def_node(node, prefix, in_singleton_class, module_function_active, out)
        return if prefix.empty?

        kind = node.receiver.is_a?(Prism::SelfNode) || in_singleton_class ? :singleton : :instance
        class_name = prefix.join("::")
        @module_function_methods << [class_name, node.name] if module_function_active && kind == :instance
        out << [node, class_name, kind]
      end

      # Wraps `MethodCandidate.new` so every candidate carries the per-file `@namespace_kinds` map AND the
      # `@class_shells` set — the Writer's nested-syntax emission consults both to pick `module` vs `class` for
      # each segment and to emit empty `Const = Data.define(...)` declarations.
      #
      # It is also where every rendered line is PARSED before it can leave the generator (see
      # {SigGen::RbsValidity}). This is the one construction point all candidates pass through, so guarding it
      # covers every mode — `--print`, `--diff`, `--write`, and the MCP surface — rather than each emit site
      # separately. A line `rbs` rejects demotes the candidate to `:skipped` instead of being emitted: a
      # signature we cannot parse is worse than no signature, because it takes the whole FILE down with it
      # (the consumer quarantines it, so every other type in that file vanishes too).
      def build_candidate(**fields)
        fields = demote_unrenderable(fields)
        MethodCandidate.new(
          namespace_kinds: @namespace_kinds,
          class_shells: @class_shells.to_a,
          class_superclasses: @class_superclasses,
          **fields
        )
      end

      def demote_unrenderable(fields)
        error = RbsValidity.method_line_error(fields[:rbs])
        return fields if error.nil?

        @unrenderable << UnrenderableMethod.new(
          path: fields[:path], class_name: fields[:class_name],
          method_name: fields[:method_name], rbs: fields[:rbs], error: error
        )
        fields.merge(
          classification: Classification::SKIPPED, skip_reason: :unrenderable_rbs, rbs: nil
        )
      end

      # Returns "def self." (kind: :singleton), "def self?." (instance method declared inside a
      # `module_function` region — both instance + singleton dispatch at runtime), or "def " (plain instance).
      def method_def_prefix(class_name, method_name, kind)
        return "def self." if kind == :singleton
        return "def self?." if @module_function_methods.include?([class_name, method_name])

        "def "
      end

      # Slice-4 follow-up surfaced by the Rigor self-dogfood: most `lib/rigor/cli/*` files have a small public
      # surface (`run`) and many private helpers. Emitting the private helpers into a `sig/` file is noise —
      # private methods are implementation details, not part of the type contract downstream consumers (Steep,
      # IDE, gem users) read. The default now skips private and protected methods; the `:include_private` flag
      # restores the slice-4 behaviour for callers that want every method.
      def visibility_excludes?(def_node, class_name, kind, scope_index)
        return false if kind == :singleton
        return false if @include_private

        scope = scope_index[def_node] || scope_index.each_value.first
        return false if scope.nil?

        visibility = scope.discovered_method_visibility(class_name, def_node.name)
        %i[private protected].include?(visibility)
      end

      # Ruby's `initialize` return value is never meaningful; the conventional RBS spelling is `() -> void`. The
      # body-typing path types the last expression (often an ivar assignment whose rvalue happens to be `[]` /
      # `{}`), which produces nonsense return types.
      #
      # Skipping `initialize` entirely is correct ONLY for default constructors — the
      # `Object#initialize: () -> void` RBS fallback then covers the lookup. When the class has a non-trivial
      # `initialize(argv:, ...)` (i.e. any parameter), partial-class sigs trip Steep's method-parameter-mismatch
      # check: Steep sees the runtime `def initialize(...)` and compares against the inherited
      # `Object#initialize: () -> void`. The mismatch surfaces a `Ruby::MethodParameterMismatch` warning even
      # when `rigor check` itself is clean.
      #
      # Returning `nil` here causes `classify_def` to skip emission; returning `:emit_stub` causes
      # `initialize_stub_candidate` to emit a permissive `(<param shape>) -> void` stub matching the runtime
      # parameter list.
      def initialize_excludes?(def_node, kind)
        return false unless kind == :instance
        return false unless def_node.name == :initialize

        # Default constructor with no params — skip; the Object#initialize RBS fallback covers it.
        params = def_node.parameters
        params.nil? || trivial_initialize_params?(params)
      end

      def trivial_initialize_params?(params)
        return true unless params.is_a?(Prism::ParametersNode)

        params.requireds.empty? && params.optionals.empty? &&
          params.rest.nil? && params.keywords.empty? &&
          params.keyword_rest.nil? && params.block.nil?
      end

      def non_trivial_initialize?(def_node, kind)
        kind == :instance && def_node.name == :initialize && !trivial_initialize_params?(def_node.parameters)
      end

      # Emits `def initialize: (<shape>) -> void`. The return is always `void` because Ruby's `initialize`
      # return value is never meaningful. The parameter list mirrors the runtime shape (required / optional /
      # rest / keyword / keyword-rest / block).
      #
      # When `--params=observed` populates `@observations` for `[class_name, :initialize]` (via the
      # `ObservationCollector`'s `.new` → `:initialize` routing), positional and keyword arg types come from the
      # per-position / per-keyword union of observed types; otherwise every position keeps `untyped` per ADR-5
      # clause 2.
      def initialize_stub_candidate(path, def_node, class_name)
        params = def_node.parameters
        rbs = "def initialize: (#{render_initialize_param_list(params, class_name)})" \
              "#{block_signature_suffix(params)} -> void"
        build_candidate(
          path: path, class_name: class_name, method_name: :initialize,
          kind: :instance, classification: Classification::NEW_METHOD,
          inferred_return: Type::Combinator.untyped, rbs: rbs
        )
      end

      def render_initialize_param_list(params, class_name)
        return "" unless params.is_a?(Prism::ParametersNode)

        observations = initialize_observations(class_name, params)
        offset = 0
        parts = []

        params.requireds.each_with_index do |_, i|
          parts << initialize_positional_type(observations, offset + i, "")
        end
        offset += params.requireds.size

        params.optionals.each_with_index do |_, i|
          parts << initialize_positional_type(observations, offset + i, "?")
        end

        parts << "*untyped" if params.rest
        params.keywords.each { |kw| parts << render_keyword_param(kw, observations) }
        parts << "**untyped" if params.keyword_rest
        parts.join(", ")
      end

      # The RBS block suffix for a `def` that takes a `&block` parameter, e.g. ` ?{ (*untyped) -> untyped }`.
      # A block belongs AFTER the parameter parens in RBS (`(params) ?{ block } -> ret`), not inside them —
      # emitting it as a comma-joined member produced `(**untyped, ?{ (?) -> void })`, which RBS rejects
      # (`optional keyword argument type is expected`) and which then collapsed the whole env build. sig-gen
      # never observes the block's own signature, so it is rendered maximally lenient (ADR-5): an optional
      # block (`?{`, since a `&block` need not be passed) taking `*untyped` and returning `untyped`. Returns
      # "" when the method takes no block.
      def block_signature_suffix(params)
        return "" unless params.is_a?(Prism::ParametersNode)
        return "" if params.block.nil?

        " ?{ (*untyped) -> untyped }"
      end

      # Picks observations under `[class_name, :initialize]` whose positional arity matches the def's accepted
      # range (required..required+optional). Looser arities don't get used because they describe a different
      # overload the stub cannot express.
      def initialize_observations(class_name, params)
        return [] if @observations.empty?

        list = @observations[[class_name, :initialize]] || []
        min = params.requireds.size
        max = min + params.optionals.size
        list.select { |obs| (min..max).cover?(obs.positional.size) }
      end

      def initialize_positional_type(observations, index, prefix)
        types = observations.filter_map { |obs| obs.positional[index] }
        "#{prefix}#{types.empty? ? 'untyped' : paren_wrap_union(union_erase(types))}"
      end

      def render_keyword_param(keyword, observations)
        optional_marker = keyword.is_a?(Prism::OptionalKeywordParameterNode) ? "?" : ""
        types = observations.filter_map { |obs| obs.keyword[keyword.name] }
        rendered = types.empty? ? "untyped" : paren_wrap_union(union_erase(types))
        "#{optional_marker}#{keyword.name}: #{rendered}"
      end

      def qualified_constant_path(constant_path)
        case constant_path
        when Prism::ConstantReadNode
          constant_path.name.to_s
        when Prism::ConstantPathNode
          parent = qualified_constant_path(constant_path.parent) if constant_path.parent
          name = constant_path.name&.to_s
          return nil if name.nil?

          parent ? "#{parent}::#{name}" : name
        end
      end

      def classify_def(path, def_node, class_name, kind, scope_index)
        return nil if visibility_excludes?(def_node, class_name, kind, scope_index)
        return nil if initialize_excludes?(def_node, kind)
        return initialize_stub_candidate(path, def_node, class_name) if non_trivial_initialize?(def_node, kind)

        unless simple_parameter_shape?(def_node.parameters)
          return skipped(path, def_node, class_name, kind, :complex_shape)
        end

        inferred = infer_return_type(def_node, scope_index)
        return skipped(path, def_node, class_name, kind, :untyped_return) if inferred.nil? || dynamic_top?(inferred)

        environment = scope_index[def_node]&.environment
        method_def = lookup_existing_method(class_name, def_node.name, kind, environment, scope_index[def_node])

        if method_def.nil?
          new_method_candidate(path, def_node, class_name, kind, inferred)
        else
          compare_against_declared(path, def_node, class_name, kind, inferred, method_def)
        end
      end

      # Required positionals only; the MVP's body-typing path gives well-defined returns for that shape.
      # Optional / rest / keyword / block parameters route through the `sig.skipped.complex-shape` reason until
      # slices 3+ widen the param policy.
      def simple_parameter_shape?(params)
        return true if params.nil?
        return false unless params.is_a?(Prism::ParametersNode)

        params.optionals.empty? &&
          params.rest.nil? &&
          params.keywords.empty? &&
          params.keyword_rest.nil? &&
          params.block.nil?
      end

      # Mirrors the `def.return-type-mismatch` rule's body-type extraction: type the implicit-return expression
      # under the scope the indexer associated with the body. The parameter bindings (typed `untyped` per the
      # indexer's default) come from `with_local` inside `StatementEvaluator`; the result is the carrier the
      # body proves *given an untyped argument tuple*.
      #
      # Post-dogfood enhancement: walk the body's AST for explicit `return X` statements and union their value
      # types with the implicit-return expression's type. The earlier MVP only typed the implicit-return path,
      # which routinely produced single-branch artefacts like `parse_options: () -> nil` (the actual runtime
      # return is `options | nil`) or `find: () -> V` (actually `V | nil` via `return nil unless ...`). The walk
      # excludes nested `DefNode` / lambda / block scopes whose returns belong to different methods. Delegates
      # to {Rigor::Inference::DefReturnTyper} — the same body-typing + explicit-return-union the `rigor
      # annotate` def-line annotator uses.
      def infer_return_type(def_node, scope_index)
        Inference::DefReturnTyper.call(def_node, scope_index)
      end

      def dynamic_top?(type)
        return true if type.is_a?(Type::Dynamic)
        return true if type.respond_to?(:top?) && type.top?.yes?

        # Post-dogfood: when explicit-return union absorbs Dynamic and the carrier ends up as a Union
        # containing `Dynamic[top]`, the Bug-1 erasure rule renders it as `untyped`. Emitting
        # `def m: () -> untyped` is the `sig.skipped.untyped-return` case — obscures rather than helps — so the
        # skip check considers the erased form too.
        type.respond_to?(:erase_to_rbs) && type.erase_to_rbs == "untyped"
      end

      def lookup_existing_method(class_name, method_name, kind, environment, scope)
        return nil if environment.nil?

        if kind == :singleton
          Reflection.singleton_method_definition(class_name, method_name, scope: scope, environment: environment)
        else
          Reflection.instance_method_definition(class_name, method_name, scope: scope, environment: environment)
        end
      end

      def new_method_candidate(path, def_node, class_name, kind, inferred)
        build_candidate(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: kind,
          classification: Classification::NEW_METHOD,
          inferred_return: inferred,
          rbs: render_rbs_line(def_node, inferred, class_name, kind)
        )
      end

      def compare_against_declared(path, def_node, class_name, kind, inferred, method_def)
        declared = build_declared_return(method_def)
        declared_rbs = declared&.erase_to_rbs
        inferred_rbs = inferred.erase_to_rbs

        if declared.nil? || declared_rbs == inferred_rbs
          return equivalent(path, def_node, class_name, kind, inferred, declared_rbs)
        end

        unless tighter?(declared, inferred) && !computed_literal_tightening?(inferred, def_node)
          return equivalent(path, def_node, class_name, kind, inferred, declared_rbs)
        end

        build_candidate(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: kind,
          classification: Classification::TIGHTER_RETURN,
          inferred_return: inferred,
          declared_return_rbs: declared_rbs,
          rbs: render_rbs_line(def_node, inferred, class_name, kind)
        )
      end

      def build_declared_return(method_def)
        translated = method_def.method_types.filter_map { |mt| translate_method_type_return(mt) }
        return nil if translated.empty?

        translated.size == 1 ? translated.first : Type::Combinator.union(*translated)
      end

      def translate_method_type_return(method_type)
        Inference::RbsTypeTranslator.translate(
          method_type.type.return_type,
          self_type: nil, instance_type: nil, type_vars: {}
        )
      rescue StandardError
        nil
      end

      # ADR-14 § "What 'more precise' means". The MVP uses the engine's gradual-mode acceptance — `:strict` is
      # reserved by `Inference::Acceptance` and lands in a follow-up. The "different spelling" guard ensures we
      # never classify a same-string round-trip as tighter.
      #
      # The `loses_declared_union_member?` guard added after the Rigor self-dogfood pass refuses to classify as
      # tighter-return when the declared form is a top-level Union and the inferred form collapses one or more
      # of its declared members. The body-typing path in slice 1 only inspects the implicit-return expression,
      # so methods with `return nil unless ...` / boolean `false | true` shapes / `Float | Integer` numeric
      # alternates routinely look "tighter" while actually dropping reachable branches. Treating those as
      # equivalent matches the project rule that an inferred tightening contradicting an existing RBS member set
      # is suspected incomplete inference until proven otherwise.
      def tighter?(declared, inferred)
        return false if inferred.is_a?(Type::Dynamic)
        return false if loses_declared_lenience?(declared, inferred)

        forward = declared.accepts(inferred)
        return false unless forward.yes?

        backward = inferred.accepts(declared)
        !backward.yes?
      end

      # Composite guard: refuse to classify as tighter-return when the declared RBS expresses lenience that the
      # inferred form removes. Three cases all signal incomplete inference rather than precision gain:
      #
      # 1. Top-level union losing one or more declared members. `return nil unless ...` paths, two-valued
      #    booleans, `Float | Integer` numeric alternates.
      # 2. Generic collection narrowed to a fixed shape. `Array[T]` → `Tuple[T, ...]`, `Hash[K, V]` →
      #    HashShape — the body's last expression was a literal whose specific shape is not the method's
      #    contract.
      # 3. `untyped` type-arg replaced by a concrete form. Declared `Hash[String, untyped]` carries the author's
      #    intentional value-type lenience; the inference's narrower Union should not override it.
      def loses_declared_lenience?(declared, inferred)
        loses_declared_union_member?(declared, inferred) ||
          narrows_collection_to_shape?(declared, inferred) ||
          replaces_untyped_type_arg?(declared, inferred)
      end

      def loses_declared_union_member?(declared, inferred)
        return false unless declared.is_a?(Type::Union)

        inferred_members = inferred.is_a?(Type::Union) ? inferred.members : [inferred]
        declared.members.any? do |declared_member|
          inferred_members.none? { |im| structurally_covers?(im, declared_member) }
        end
      end

      def structurally_covers?(inferred_member, declared_member)
        return true if inferred_member == declared_member

        result = inferred_member.accepts(declared_member)
        result.respond_to?(:yes?) && result.yes?
      end

      GENERIC_COLLECTION_CLASSES = %w[
        Array Hash Set Range Enumerable Enumerator Enumerator::Lazy
      ].freeze
      private_constant :GENERIC_COLLECTION_CLASSES

      def narrows_collection_to_shape?(declared, inferred)
        return false unless declared.is_a?(Type::Nominal)
        return false unless GENERIC_COLLECTION_CLASSES.include?(declared.class_name)

        inferred.is_a?(Type::Tuple) || inferred.is_a?(Type::HashShape)
      end

      # Heuristic added after the third-round self-dogfood: `FallbackTracer#size` body is `@events.size`, where
      # `@events` is initialised to `[]` and never assigned again at the class-ivar pre-pass level. The
      # `Type::Tuple[]` (size 0) folds `.size` to `Constant<0>` — the carrier knows the empty-tuple cardinality
      # exactly. But the runtime contract is `Integer` because callers add events through other methods. The
      # signal is "the body's last expression is NOT a directly-authored literal but the inferred type IS a
      # Constant"; in that case the precision came from inference over an internal computation, not the
      # author's contract, so refuse to tighten.
      def computed_literal_tightening?(inferred, def_node)
        return false unless inferred.is_a?(Type::Constant)

        last = Inference::DefReturnTyper.body_last_expression(def_node.body)
        !direct_literal_node?(last)
      end

      DIRECT_LITERAL_NODE_TYPES = [
        Prism::IntegerNode, Prism::FloatNode, Prism::StringNode, Prism::SymbolNode,
        Prism::TrueNode, Prism::FalseNode, Prism::NilNode
      ].freeze
      private_constant :DIRECT_LITERAL_NODE_TYPES

      def direct_literal_node?(node)
        DIRECT_LITERAL_NODE_TYPES.any? { |klass| node.is_a?(klass) }
      end

      def replaces_untyped_type_arg?(declared, inferred)
        return false unless declared.is_a?(Type::Nominal) && inferred.is_a?(Type::Nominal)
        return false unless declared.class_name == inferred.class_name
        return false unless declared.type_args.size == inferred.type_args.size

        declared.type_args.zip(inferred.type_args).any? do |d_arg, i_arg|
          d_arg.is_a?(Type::Dynamic) && !i_arg.is_a?(Type::Dynamic)
        end
      end

      def equivalent(path, def_node, class_name, kind, inferred, declared_rbs)
        build_candidate(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: kind,
          classification: Classification::EQUIVALENT,
          inferred_return: inferred,
          declared_return_rbs: declared_rbs
        )
      end

      def skipped(path, def_node, class_name, kind, reason)
        build_candidate(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: kind,
          classification: Classification::SKIPPED,
          skip_reason: reason
        )
      end

      def render_rbs_line(def_node, inferred, class_name, kind)
        arity = required_arity(def_node)
        head = arity.zero? ? "()" : "(#{render_param_list(class_name, def_node.name, arity)})"
        prefix = method_def_prefix(class_name, def_node.name, kind)
        "#{prefix}#{def_node.name}: #{head} -> #{paren_wrap_union(elaborated_rbs(inferred))}"
      end

      # Routes the inferred carrier through {TypeElaborator} so bare generic nominals (`Array` / `Hash` / `Set`
      # / `Range` / `Enumerable`) get their `untyped` type parameters filled in before erasing to RBS. The
      # elaborator consults the class's RBS-declared type-parameter list via
      # `Reflection.class_type_param_names`.
      def elaborated_rbs(type)
        TypeElaborator.elaborate(type, environment: @environment).erase_to_rbs
      end

      # RBS / Steep require return-position unions to be parenthesised when they appear bare at the top level of
      # a method type — `def m: () -> 0 | 1` fails the parser because the trailing `| 1` isn't a valid
      # method-type start. Wrap when the erased form is a top-level union; single types and already-bracketed
      # forms (e.g. `Array[A | B]`) parse without wrapping.
      def paren_wrap_union(rendered)
        top_level_union?(rendered) ? "(#{rendered})" : rendered
      end

      def top_level_union?(rendered)
        return false unless rendered.include?(" | ")

        depth = 0
        rendered.each_char.with_index do |ch, i|
          case ch
          when "(", "[", "{" then depth += 1
          when ")", "]", "}" then depth -= 1
          when " "
            return true if depth.zero? && rendered[i + 1] == "|"
          end
        end
        false
      end

      def required_arity(def_node)
        params = def_node.parameters
        params.is_a?(Prism::ParametersNode) ? params.requireds.size : 0
      end

      # Per ADR-5 clause 2 the default is `untyped` for every position. Observed-policy callers
      # (`--params=observed`) pass an `observations:` map at construction time; the generator unions
      # per-position arg types whose tuple arity matches the def's required-positional count. Observations from
      # arities other than the def's count are discarded — they describe a different overload the MVP does not
      # emit.
      def render_param_list(class_name, method_name, arity)
        tuples = matching_observations(class_name, method_name, arity)
        return Array.new(arity, "untyped").join(", ") if tuples.empty?

        Array.new(arity) { |i| union_erase(tuples.map { |obs| obs.positional[i] }) }.join(", ")
      end

      def matching_observations(class_name, method_name, arity)
        return [] if @observations.empty?

        list = @observations[[class_name, method_name]] || []
        list.select { |obs| obs.positional.size == arity }
      end

      def union_erase(types)
        return "untyped" if types.empty?
        return elaborated_rbs(types.first) if types.size == 1

        # `Type::Combinator.union` dedupes by structural type equality. The carrier-level `erase_to_rbs` now
        # absorbs `untyped` members and dedupes the post-erase strings (`String | String` → `String` for
        # distinct `Constant<"Alice">` / `Constant<"Bob">` envelopes), so the sig-gen layer only needs to
        # elaborate bare generics before erasing.
        elaborated_rbs(Type::Combinator.union(*types))
      end

      # ADR-14 slice 4 — `attr_reader` / `attr_writer` / `attr_accessor` recognition. Each Symbol-named entry in
      # the call's argument list yields one or two {MethodCandidate}s whose inferred return type is the
      # corresponding instance-variable's accumulated type from `Scope#class_ivars_for(class_name)`.
      # `attr_reader` adds one reader candidate; `attr_writer` adds one `name=`-method writer candidate;
      # `attr_accessor` adds both.
      ATTR_METHOD_NAMES = %i[attr_reader attr_writer attr_accessor].freeze
      private_constant :ATTR_METHOD_NAMES

      ATTR_KINDS = {
        attr_reader: [:reader],
        attr_writer: [:writer],
        attr_accessor: %i[reader writer]
      }.freeze
      private_constant :ATTR_KINDS

      # Per-file context the attr_* walker threads through its recursive descent. Keeps parameter lists in
      # check. `obs_ivar_map` carries the observation-derived fallback types built by
      # {#build_observed_ivar_map}; it is empty when sig-gen is invoked without `--params=observed`.
      AttrWalkContext = Struct.new(:path, :scope_index, :obs_ivar_map, :out, keyword_init: true)
      private_constant :AttrWalkContext

      def collect_attr_candidates(root, path, scope_index, obs_ivar_map = {})
        ctx = AttrWalkContext.new(path: path, scope_index: scope_index,
                                  obs_ivar_map: obs_ivar_map, out: [])
        walk_attr_calls(root, [], false, ctx)
        ctx.out
      end

      def walk_attr_calls(node, prefix, in_singleton_class, ctx)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_constant_path(node.constant_path)
          if name
            walk_attr_calls(node.body, prefix + [name], false, ctx) if node.body
            return
          end
        when Prism::SingletonClassNode
          walk_attr_calls(node.body, prefix, true, ctx) if node.body
          return
        when Prism::DefNode
          # Skip method bodies — attr_* there would refer to whatever the method is doing dynamically, not a
          # class-level declaration.
          return
        when Prism::ConstantWriteNode
          body = meta_block_body(node, prefix)
          if body
            walk_attr_calls(body, prefix + [node.name.to_s], false, ctx)
            return
          end
        when Prism::CallNode
          collect_attr_call(node, prefix, in_singleton_class, ctx)
        end

        node.rigor_each_child { |child| walk_attr_calls(child, prefix, in_singleton_class, ctx) }
      end

      def collect_attr_call(call_node, prefix, in_singleton_class, ctx)
        return unless ATTR_METHOD_NAMES.include?(call_node.name)
        return if prefix.empty?
        return if in_singleton_class

        class_name = prefix.join("::")
        symbol_names = extract_symbol_arguments(call_node)
        return if symbol_names.empty?

        ivar_lookup = ivar_type_lookup(ctx.scope_index, class_name, ctx.obs_ivar_map)
        symbol_names.each do |attr_name|
          ivar_type = ivar_lookup.call(attr_name)
          ctx.out.concat(build_attr_candidates(call_node.name, class_name, attr_name, ivar_type, ctx))
        end
      end

      def extract_symbol_arguments(call_node)
        Source::Literals.symbol_arguments(call_node)
      end

      # Returns a closure that looks up `:@<attr_name>` in the class-ivar accumulator carried by the first scope
      # the indexer associated with this file. The accumulator is populated by
      # `ScopeIndexer#build_class_ivar_index` before any statement evaluation runs, so the lookup works even
      # when attr_* declarations come before the corresponding ivar writes lexically.
      #
      # When `obs_ivar_map` is non-empty (i.e. `--params=observed` was used), it acts as a fallback: if the ivar
      # pre-pass resolved the type to `nil` or `Dynamic[top]` — typically because `@ivar = param` inside
      # `initialize` typed the param as `untyped` — the observation-derived type is substituted. This lets
      # `attr_reader :name` emit a concrete type when `ClassName.new("alice")` call sites are visible to the
      # observation scan.
      def ivar_type_lookup(scope_index, class_name, obs_ivar_map = {})
        any_scope = scope_index.each_value.first
        return ->(_) {} if any_scope.nil?

        ivars     = any_scope.class_ivars_for(class_name)
        obs_ivars = obs_ivar_map[class_name] || {}
        lambda do |attr_name|
          type = ivars[:"@#{attr_name}"]
          type.nil? || dynamic_top?(type) ? obs_ivars[attr_name] : type
        end
      end

      # Build a { class_name => { attr_name_sym => Type } } map that records observation-derived types for
      # ivars assigned directly from `def initialize` parameters. Only populated when `@observations` is
      # non-empty (i.e. `--params=observed` was supplied). Matches the pattern `@ivar_name = param_name` where
      # `param_name` is a required / optional positional or keyword parameter of `initialize`.
      def build_observed_ivar_map(root)
        return {} if @observations.empty?

        result = {}
        collect_init_ivar_obs(root, [], result)
        result
      end

      def collect_init_ivar_obs(node, prefix, result)
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_constant_path(node.constant_path)
          if name
            collect_init_ivar_obs(node.body, prefix + [name], result) if node.body
            return
          end
        when Prism::DefNode
          if node.name == :initialize && !prefix.empty?
            class_name = prefix.join("::")
            map = ivar_obs_from_initialize(class_name, node)
            result[class_name] = (result[class_name] || {}).merge(map) unless map.empty?
          end
          return
        end

        node.rigor_each_child { |c| collect_init_ivar_obs(c, prefix, result) }
      end

      # Derive { attr_name_sym => Type } for a single `def initialize` by matching `@ivar = param_name`
      # assignments against the available `[class_name, :initialize]` observations.
      def ivar_obs_from_initialize(class_name, def_node)
        obs_list = @observations[[class_name, :initialize]]
        return {} if obs_list.nil? || obs_list.empty?
        return {} if def_node.body.nil? || def_node.parameters.nil?

        param_index = build_init_param_index(def_node.parameters)
        return {} if param_index.empty?

        ivar_to_param = {}
        scan_ivar_param_assignments(def_node.body, param_index.keys.to_set, ivar_to_param)
        build_ivar_obs_type_map(ivar_to_param, param_index, obs_list)
      end

      # Map `{ ivar_name => param_name }` → `{ attr_name_sym => Type }` by looking up each param's observation
      # types and unioning them.
      def build_ivar_obs_type_map(ivar_to_param, param_index, obs_list)
        ivar_to_param.filter_map do |ivar_name, param_name|
          types = collect_param_obs_types(obs_list, param_name, param_index[param_name])
          next if types.empty?

          attr_name = ivar_name.to_s.delete_prefix("@").to_sym
          [attr_name, types.reduce { |acc, t| Type::Combinator.union(acc, t) }]
        end.to_h
      end

      # Collect observed argument types for a single parameter across all call-site observations. Returns an
      # array of Type objects (may be empty).
      def collect_param_obs_types(obs_list, param_name, param_info)
        case param_info[:kind]
        when :positional then obs_list.filter_map { |obs| obs.positional[param_info[:index]] }
        when :keyword    then obs_list.filter_map { |obs| obs.keyword[param_name] }
        else []
        end
      end

      # Map param_name_sym → { kind: :positional, index: N } or { kind: :keyword } for required / optional
      # positionals and required / optional keywords of a ParametersNode.
      def build_init_param_index(parameters)
        index  = {}
        offset = 0

        (parameters.requireds || []).each_with_index do |p, i|
          index[p.name] = { kind: :positional, index: offset + i } if p.respond_to?(:name)
        end
        offset += parameters.requireds&.size || 0

        (parameters.optionals || []).each_with_index do |p, i|
          index[p.name] = { kind: :positional, index: offset + i } if p.respond_to?(:name)
        end

        (parameters.keywords || []).each do |kw|
          index[kw.name] = { kind: :keyword } if kw.respond_to?(:name)
        end

        index
      end

      # Walk a def body for direct `@ivar = local_var` assignments where `local_var` is one of the listed
      # parameter names. Records ivar_name (Symbol with `@` prefix) → param_name. Does not recurse into nested
      # defs / classes / modules.
      def scan_ivar_param_assignments(node, param_names, result)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::InstanceVariableWriteNode) &&
           node.value.is_a?(Prism::LocalVariableReadNode) &&
           param_names.include?(node.value.name)
          result[node.name] ||= node.value.name
        end

        return if node.is_a?(Prism::DefNode) ||
                  node.is_a?(Prism::ClassNode) ||
                  node.is_a?(Prism::ModuleNode)

        node.rigor_each_child { |c| scan_ivar_param_assignments(c, param_names, result) }
      end

      def build_attr_candidates(call_name, class_name, attr_name, ivar_type, ctx)
        ATTR_KINDS.fetch(call_name).flat_map do |variant|
          method_name = variant == :writer ? :"#{attr_name}=" : attr_name
          candidate = build_attr_candidate(class_name, method_name, variant, ivar_type, ctx)
          candidate ? [candidate] : []
        end
      end

      def build_attr_candidate(class_name, method_name, variant, ivar_type, ctx)
        if ivar_type.nil? || dynamic_top?(ivar_type)
          return attr_skipped(ctx.path, class_name, method_name, :untyped_return)
        end

        scope = ctx.scope_index.each_value.first
        environment = scope&.environment
        method_def = lookup_existing_method(class_name, method_name, :instance, environment, scope)
        if method_def.nil?
          attr_new_candidate(ctx.path, class_name, method_name, variant, ivar_type)
        else
          attr_compare_against_declared(ctx.path, class_name, method_name, variant, ivar_type, method_def)
        end
      end

      def attr_new_candidate(path, class_name, method_name, variant, ivar_type)
        build_candidate(
          path: path,
          class_name: class_name,
          method_name: method_name,
          kind: :instance,
          classification: Classification::NEW_METHOD,
          inferred_return: ivar_type,
          rbs: render_attr_rbs_line(method_name, variant, ivar_type)
        )
      end

      def attr_compare_against_declared(path, class_name, method_name, variant, ivar_type, method_def)
        declared = build_declared_return(method_def)
        declared_rbs = declared&.erase_to_rbs
        inferred_rbs = ivar_type.erase_to_rbs

        if declared.nil? || declared_rbs == inferred_rbs || !tighter?(declared, ivar_type)
          return attr_equivalent(path, class_name, method_name, ivar_type, declared_rbs)
        end

        build_candidate(
          path: path, class_name: class_name, method_name: method_name,
          kind: :instance, classification: Classification::TIGHTER_RETURN,
          inferred_return: ivar_type, declared_return_rbs: declared_rbs,
          rbs: render_attr_rbs_line(method_name, variant, ivar_type)
        )
      end

      def attr_equivalent(path, class_name, method_name, ivar_type, declared_rbs)
        build_candidate(
          path: path, class_name: class_name, method_name: method_name,
          kind: :instance, classification: Classification::EQUIVALENT,
          inferred_return: ivar_type, declared_return_rbs: declared_rbs
        )
      end

      def attr_skipped(path, class_name, method_name, reason)
        build_candidate(
          path: path, class_name: class_name, method_name: method_name,
          kind: :instance, classification: Classification::SKIPPED, skip_reason: reason
        )
      end

      # Slice 4 emits attr_* in the long-form `def` spelling so the existing writer's `MethodDefinition`-based
      # merge path applies without extra wiring. Users who prefer the idiomatic `attr_reader name: Type` short
      # form can normalise post-emit; the writer-side member detection (slice 2) treats existing `attr_*`
      # declarations as user-authored so a paired source-side `attr_reader` never produces a duplicate `def`
      # insertion.
      def render_attr_rbs_line(method_name, variant, ivar_type)
        erased = elaborated_rbs(ivar_type)
        wrapped = paren_wrap_union(erased)
        case variant
        when :reader then "def #{method_name}: () -> #{wrapped}"
        when :writer then "def #{method_name}: (#{erased}) -> #{wrapped}"
        end
      end

      # One candidate per member accessor and constructor {MetaClassShape} renders for each layout-carrying class.
      # These are the members no `def` or `attr_*` in the source declares, so nothing else in sig-gen can find them —
      # and once `register_meta_classes` has declared the class, an undeclared member reads as a missing one.
      def collect_meta_member_candidates(path, scope_index)
        return [] if @meta_layouts.empty?

        scope = scope_index.each_value.first
        environment = scope&.environment
        @meta_layouts.flat_map do |class_name, layout|
          types = meta_member_types(class_name, layout.member_names)
          shape = MetaClassShape.of(
            kind: layout.kind, members: layout.member_names, keyword_init: layout.keyword_init,
            member_types: types.transform_values { |type| paren_wrap_union(union_erase([type])) }
          )
          shape.member_decls.filter_map do |member|
            meta_member_candidate(path, class_name, member, types, scope, environment)
          end
        end
      end

      def meta_member_candidate(path, class_name, member, types, scope, environment)
        existing = lookup_existing_method(class_name, member.method_name, member.kind, environment, scope)
        return nil if declared_on_class_itself?(existing, class_name)

        build_candidate(
          path: path, class_name: class_name, method_name: member.method_name, kind: member.kind,
          classification: Classification::NEW_METHOD,
          inferred_return: types[member.source_member] || Type::Combinator.untyped,
          rbs: member.rbs
        )
      end

      # Whether an RBS declaration found for a member is the user's own, i.e. sits on this very class. Inheritance
      # is the whole point of the distinction: `::Data.new: () -> bot` and `::Struct.new`'s factory both answer the
      # `.new` lookup for every value class, and deferring to them is what leaves the arity false positive in place.
      def declared_on_class_itself?(method_def, class_name)
        return false if method_def.nil?
        return false unless method_def.respond_to?(:defined_in)

        method_def.defined_in.to_s.delete_prefix("::") == class_name
      end

      # `--params=observed` member types. {ObservationCollector} routes `Point.new(...)` call sites to
      # `[class_name, :initialize]`, so a keyword call site names its member directly, while a positional one is
      # matched by index — and only from call sites whose arity covers the whole member list, so a one-argument
      # `Point.new(attrs)` shim cannot type member 0 as `Hash`. Empty without `--params=observed`.
      def meta_member_types(class_name, members)
        observations = @observations[[class_name, :initialize]] || []
        return {} if observations.empty?

        full_arity = observations.select { |obs| obs.positional.size == members.size }
        members.each_with_index.to_h do |member, index|
          observed = observations.filter_map { |obs| obs.keyword[member] } +
                     full_arity.filter_map { |obs| obs.positional[index] }
          [member, observed.empty? ? nil : Type::Combinator.union(*observed)]
        end.compact
      end
    end
  end
end
