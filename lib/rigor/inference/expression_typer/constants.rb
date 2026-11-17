# frozen_string_literal: true

require_relative "../../analysis/dependency_recorder"
require_relative "../../reflection"
require_relative "../../source/constant_path"
require_relative "../dynamic_origin"
require_relative "../narrowing"

module Rigor
  module Inference
    class ExpressionTyper
      # Typers of a constant read (`Foo`, `Foo::Bar`, `::Foo`): the guard narrowing, the lexical resolution through
      # `Reflection`, and the fallback record for a name that resolves to nothing. Reads `scope`; calls back
      # {ExpressionTyper#dynamic_top}, {ExpressionTyper#fallback_for} and {ExpressionTyper#record_fallback}. The entries
      # are `type_of_constant_read`, `type_of_constant_path`, `resolve_constant_name`; every other method is private to
      # the module (ADR-116 C3). State is passed, not shared: each entry takes the values it reads from the typer as
      # trailing positional parameters (`scope`, `tracer`) and the typer itself (`typer`) when it calls back.
      module Constants
        module_function

        # The expression `Foo` evaluates to the *class object* `Foo`, not an instance. From Slice 4 phase 2b on
        # we therefore type a bare-constant reference as `Singleton[Foo]`; method dispatch on that receiver
        # looks up class methods (`Foo.new`, `Foo.bar`, ...).
        #
        # Slice A constant-walk: when the literal name does not resolve, we try a lexical walk based on the
        # surrounding class context exposed through `scope.self_type` so a reference like
        # `Inference::FallbackTracer` from inside `Rigor::CLI::Foo` resolves to
        # `Rigor::Inference::FallbackTracer`.
        def type_of_constant_read(node, scope, typer)
          guard_narrowed_constant(node, scope) ||
            resolve_constant_name(node.name.to_s,
                                  scope) || unresolved_constant_fallback(node, node.name.to_s, scope, typer)
        end

        # Issue #1429 — the type a guard narrowed this constant reference to on the edge being typed
        # (`STDOUT.is_a?(StringIO) ? STDOUT.string : nil`), or nil. Keyed by spelling ({Narrowing.constant_key}).
        def guard_narrowed_constant(node, scope)
          return nil if scope.constant_narrowings.empty?

          key = Narrowing.constant_key(node)
          key && scope.constant_narrowing(key)
        end

        # A leading `::` (`::Rails`, `::Rails::Application`) is Ruby's escape hatch out of the lexical ladder:
        # it names the top-level constant whatever the enclosing nesting defines. The rendered name is
        # deliberately un-rooted (the discovery tables are keyed that way), so the marker rides alongside it
        # into the resolver (#614).
        def type_of_constant_path(node, scope, typer)
          narrowed = guard_narrowed_constant(node, scope)
          return narrowed if narrowed

          full_name = Source::ConstantPath.qualified_name_or_nil(node)
          return typer.fallback_for(node, family: :prism) if full_name.nil?

          resolve_constant_name(full_name, scope, rooted: Source::ConstantPath.rooted?(node)) ||
            unresolved_constant_fallback(node, full_name, scope, typer)
        end

        # ADR-82 WD9 — an unresolved constant whose root name a locked, RBS-less gem declares carries the
        # `external_gem_without_rbs` cause instead of the generic `unsupported_syntax`. The constant read is
        # where the class name is last visible (a no-RBS gem's receiver never types Nominal, so the dispatch
        # tiers that record this cause under ADR-10 / `pre_eval:` opt-ins can't see it); WD6 chain inheritance
        # then carries the cause through `Faraday.new.get(...)`. Side-channel only — the type stays the same
        # `Dynamic[top]`, and an unindexed constant (project typo, unanalyzed project path) keeps the generic
        # cause: the fail-open direction is a missing label, never a wrong one.
        def unresolved_constant_fallback(node, full_name, scope, typer)
          record_missing_constant(full_name) if Analysis::DependencyRecorder.active?
          root = full_name.delete_prefix("::").split("::").first
          owner = root && scope.environment.missing_rbs_gem_owner(root)
          return typer.fallback_for(node, family: :prism) unless owner

          inner = typer.dynamic_top
          typer.record_fallback(node, family: :prism, inner_type: inner, origin: DynamicOrigin::EXTERNAL_GEM_WITHOUT_RBS)
          scope.record_dynamic_origin(node, DynamicOrigin::EXTERNAL_GEM_WITHOUT_RBS)
          inner
        end

        # ADR-46 slice 3 / issue #622 — a constant reference that resolved to NOTHING is a negative cross-file
        # dependency: a file declaring that constant later must re-check every file that read it as missing.
        # Without this edge the structural tier had no record of the read at all — `read_missing(:method, …)`
        # fires only once the receiver constant has RESOLVED and the method lookup misses, so a missing
        # constant short-circuited before any edge existed, and a warm `--incremental` run kept
        # `Rails.logger`'s `Dynamic[top]` (and missed the `call.undefined-method` a full run fires) after a
        # later edit added `module Rails`.
        #
        # Reuses the existing `class:Name` negative kind (`CheckRules`'s override-ancestor miss records the
        # same one) rather than adding a `constant:` kind, because the producer that has to invert it already
        # exists: `Incremental.appeared_classes` reports a newly declared class / module by its QUALIFIED name
        # and `negative_affected` matches it by simple (last-segment) name. The snapshot row grammar is
        # therefore unchanged — no `IncrementalSnapshot::SCHEMA` bump — and a snapshot recorded by an engine
        # without this edge is already dropped by the fingerprint's engine-source part.
        #
        # The LAST segment is the whole key, and one row per reference is the whole cost: a qualified read
        # resolves only once its final segment is declared, and every constant form that resolves cross-file —
        # a `class` / `module`, and the constant-assigned `Data.define` / `Struct.new` forms — registers in the
        # discovery pre-pass's class sources under its qualified name, so its final segment always appears.
        # (A plain value constant, `FOO = 1` or a `VERSION` nested in a module, resolves in NO cross-file read
        # today, so there is nothing for a root-segment or a `constant:` key to salvage; if that changes, the
        # answer is a producer that reports appeared value constants, not a wider key here.) Simple-name
        # matching over-invalidates — a nested `MyApp::Rails` also re-checks a reader of the top-level `Rails`
        # — which is the sound direction and the grammar the class negatives already use. Consumers hold
        # `missing` as a Set, so a name repeated across a file still costs one row.
        def record_missing_constant(full_name)
          segments = full_name.delete_prefix("::").split("::")
          return if segments.empty?

          Analysis::DependencyRecorder.read_missing(:class, segments.last)
          # Issue #644's `constant:<last segment>` edge is NOT recorded here. It is recorded once per
          # reference by `Reflection.resolve_constant_type`, before the resolver ladder runs, so it covers a
          # reference that resolves through RBS or the class registry as well as one that misses — all three
          # answers move when the project's constant write set moves. Recording it again on this path would be
          # a second source of truth for the same key.
        end

        # Resolves a constant reference through Ruby's lexical constant lookup. Delegates to the shared
        # `Reflection.resolve_constant_type` owner so the same walk (registry singleton, discovered class,
        # in-source value, RBS constant, across the peeled `::` prefix candidates) is reused by
        # `Inference::Narrowing`'s `Constant[Regexp]` match-operand recognition. Returns the matched
        # `Rigor::Type` or nil; the caller decides whether to fall back.
        def resolve_constant_name(name, scope, rooted: false, caller_derived: true)
          Reflection.resolve_constant_type(name, scope: scope, rooted: rooted, caller_derived: caller_derived)
        end

        private_class_method :guard_narrowed_constant, :unresolved_constant_fallback, :record_missing_constant
      end
    end
  end
end
