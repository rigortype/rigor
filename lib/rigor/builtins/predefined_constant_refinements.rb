# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Builtins
    # Refined types for predefined Ruby / stdlib constants whose upstream RBS signatures are
    # broader than the constants' documented runtime invariants.
    #
    # Resolution is two-tiered, and **both tiers are closed tables authored in this file**. A name
    # taken from the analysed program is never resolved against the analyzer's own object space —
    # see *Why the table is closed* below.
    #
    # **Tier 1 — exact-value whitelist** (`FOLDED_CONSTANTS`):
    # Constants whose value is bit-for-bit identical across every Ruby version and platform
    # are folded to `Constant[T]`: the `Math::PI` / `Math::E` math constants (C's `M_PI` /
    # `M_E`) and the four IEEE 754 binary64 magnitude constants `Float::INFINITY` / `::MAX` /
    # `::MIN` / `::EPSILON` (each a single format-mandated bit pattern). Add new entries only
    # when the value is truly cross-implementation invariant AND compares reflexively under
    # `==` — the latter is why `Float::NAN` is deliberately EXCLUDED: `NaN == NaN` is `false`,
    # so a `Constant[NAN]` would violate the `Type::Constant` `==` / `eql?` / `hash` contract
    # (it would hash equal to itself yet compare unequal), corrupting type-equality and union
    # dedup. The binary64 *integer* shape parameters (`Float::DIG` / `MANT_DIG` / `MAX_EXP` /
    # …) are intentionally NOT folded: upstream RBS hedges them as "Usually defaults to …",
    # and as plain `Integer`s they fall through Tier 2 to the RBS type harmlessly.
    # `Complex::I` is deferred (no complex-fold consumer).
    #
    # **Tier 2 — String refinements for a closed set of interpreter constants**
    # (`RUNTIME_STRING_CONSTANTS`): each listed name is read ONCE, at load time, from the analyzer's
    # own runtime and classified by the value found:
    #
    # - not a String, or an empty one  → no entry (the name falls through to the RBS type)
    # - a Ruby numeric literal  → `numeric-string`
    # - non-empty otherwise  → `non-empty-string`
    #
    # Admission criterion for the list: the constant's value is fixed by the same interpreter choice
    # that already fixes the core / stdlib RBS the engine reads, and it is non-empty in every build.
    # A third-party gem's constant does NOT qualify — the analysed project resolves its own copy
    # through its `Gemfile.lock`, which this layer cannot see. This is the criterion
    # `Inference::VersionGuard::VERSION_CONSTANTS` already applies to the constants it folds guards on.
    #
    # **Why the table is closed** ([#680](https://github.com/rigortype/rigor/issues/680)):
    # Tier 2 used to resolve ANY name reaching it — a name read out of the analysed source — with
    # `const_get` against the analyzer's runtime, guarded by `const_defined?(part, false)`. That
    # guard does not answer the question it was written for: `const_defined?` is true for a
    # **registered but not yet triggered autoload**, so `const_get` fired the autoload and the target
    # file was *executed* inside the analyzer. Analysing CRuby's own `lib/prism` reached
    # `prism/translation/ruby_parser.rb`, which calls `exit` at the top level when `sexp_processor`
    # is absent; `SystemExit` is not a `StandardError`, so neither the rescue in this file nor the
    # runner's per-file rescue saw it and the run stopped with no diagnostics and no summary. The
    # target of an autoload is arbitrary — it may exit, raise, print, mutate global state, or take
    # unbounded time — and `rigor check` is routinely pointed at code the user did not write.
    #
    # Closing the table rather than only guarding the walk is what makes that structural: no name
    # from the analysed program reaches `const_get` at all. A census of what the open walk actually
    # bought says the precision cost is nil — over GitLab's `app` + `lib` (11,189 files, 184,965
    # constant references) it answered for five names and ten references (`RUBY_VERSION`,
    # `RUBY_PLATFORM`, `RUBY_DESCRIPTION`, `File::SEPARATOR`, `File::PATH_SEPARATOR`, every one of
    # them listed below), against 17 references that would have autoloaded `ipaddr`; over Mastodon,
    # three names and five references against 43 such. What it answered for *beyond* the list was
    # always a constant that happened to live in **Rigor's own** bundle — `Rigor::VERSION` and
    # `RBS::VERSION` while Rigor checks itself, rubygems and Bundler internals while it checks
    # CRuby's `lib/` — and that is worse than no answer: identical source would type differently
    # depending on how the analyzer was installed. Removing an ad hoc `Object.const_get` from an
    # analysis path is the same move ADR-4 § 330 already made for predicate narrowing.
    #
    # This module is consulted by `Environment#constant_for_name` BEFORE the RBS
    # constant-type table (widest types) but AFTER in-source constant writes (the user's own
    # `Math::PI = 0.0` takes precedence via the lexical-candidate walk in `ExpressionTyper`).
    module PredefinedConstantRefinements
      # --- tier 1 -------------------------------------------------------

      # Exact-value fold whitelist.  Keys are unqualified constant paths (no leading "::")
      # matching what `Environment#constant_for_name` receives.
      FOLDED_CONSTANTS = {
        # Math module — IEEE 754 bit-identical across all MRI / JRuby / TruffleRuby builds;
        # folding enables precise constant arithmetic.
        "Math::PI" => Type::Combinator.constant_of(::Math::PI).freeze,
        "Math::E" => Type::Combinator.constant_of(::Math::E).freeze,

        # Float magnitude limits — each a single format-mandated IEEE 754 binary64 bit
        # pattern (`+Inf`, `DBL_MAX`, `DBL_MIN`, `DBL_EPSILON`), reflexive under `==`.
        # `Float::NAN` is excluded (non-reflexive `==` — see the module-level note).
        "Float::INFINITY" => Type::Combinator.constant_of(::Float::INFINITY).freeze,
        "Float::MAX" => Type::Combinator.constant_of(::Float::MAX).freeze,
        "Float::MIN" => Type::Combinator.constant_of(::Float::MIN).freeze,
        "Float::EPSILON" => Type::Combinator.constant_of(::Float::EPSILON).freeze
      }.freeze
      private_constant :FOLDED_CONSTANTS

      # --- tier 2 -------------------------------------------------------

      # The closed set of names tier 2 may read, by the admission criterion in the module note.
      #
      # The `RUBY_*` / `Ruby::*` pairs and `Encoding::UNICODE_VERSION` are defined by the interpreter
      # itself; `File::SEPARATOR` / `PATH_SEPARATOR` / `ALT_SEPARATOR` by its `File` core class
      # (`ALT_SEPARATOR` is `nil` off Windows, and simply gets no entry there); `Gem::VERSION` by the
      # rubygems every `rigor` process has already loaded. A name that resolves to something other
      # than a non-empty String on the running interpreter is skipped, so listing one costs nothing
      # where it does not exist.
      RUNTIME_STRING_CONSTANTS = %w[
        RUBY_VERSION RUBY_RELEASE_DATE RUBY_PLATFORM RUBY_DESCRIPTION RUBY_COPYRIGHT
        RUBY_ENGINE RUBY_ENGINE_VERSION RUBY_REVISION
        Ruby::VERSION Ruby::RELEASE_DATE Ruby::PLATFORM Ruby::DESCRIPTION Ruby::COPYRIGHT
        Ruby::ENGINE Ruby::ENGINE_VERSION Ruby::REVISION
        File::SEPARATOR File::PATH_SEPARATOR File::ALT_SEPARATOR
        Encoding::UNICODE_VERSION
        Gem::VERSION
      ].freeze
      private_constant :RUNTIME_STRING_CONSTANTS

      NON_EMPTY_STRING = Type::Combinator.non_empty_string.freeze
      NUMERIC_STRING   = Type::Combinator.numeric_string.freeze
      private_constant :NON_EMPTY_STRING, :NUMERIC_STRING

      # --- private ------------------------------------------------------

      # @param value [String] a non-empty string
      # @return [Rigor::Type]
      def self.classify_string(value)
        if Type::Refined.ruby_numeric_literal?(value)
          NUMERIC_STRING
        else
          NON_EMPTY_STRING
        end
      end
      private_class_method :classify_string

      # Reads `name` in the analyzer's runtime, returning its value when that is a non-empty String.
      #
      # Called ONLY with the names in {RUNTIME_STRING_CONSTANTS} — Rigor's own source — and only
      # while this file is being loaded. It is never handed a name from the analysed program.
      #
      # @param name [String] a qualified constant path without a leading "::"
      # @return [String, nil]
      def self.runtime_string_value(name)
        mod = ::Object
        name.split("::").each do |part|
          return nil unless mod.is_a?(::Module) && mod.const_defined?(part, false)
          # `const_defined?` is true for a REGISTERED-BUT-NOT-YET-TRIGGERED autoload, so on its own
          # it does not mean "already in memory" and `const_get` would EXECUTE the target file. Only
          # `Module#autoload?` separates the two: it returns the registered path while the autoload
          # is pending and nil once it has run, so declining on it declines exactly the dangerous
          # case and still resolves a constant genuinely loaded ([#680]).
          return nil if mod.autoload?(part)

          mod = mod.const_get(part, false)
        end

        mod.is_a?(::String) && !mod.empty? ? mod : nil
      rescue ::StandardError, ::ScriptError, ::SystemExit
        # Deliberately wider than the `NameError` / `TypeError` / `LoadError` this used to name.
        # Refining a constant is an optimisation and nothing it can hit justifies stopping the
        # process; `SystemExit` is the one that actually did ([#680]) and is not a `StandardError`,
        # and `ScriptError` covers the `LoadError` family for the same reason. `Interrupt`,
        # `SignalException` and `NoMemoryError` are deliberately NOT caught — a Ctrl-C must keep
        # reaching the user, and an out-of-memory process is not one to keep analysing in.
        nil
      end
      private_class_method :runtime_string_value

      # @return [Hash{String => Rigor::Type}] frozen, built once at load time.
      def self.build_runtime_string_refinements
        RUNTIME_STRING_CONSTANTS.each_with_object({}) do |name, table|
          value = runtime_string_value(name)
          table[name] = classify_string(value) if value
        end.freeze
      end
      private_class_method :build_runtime_string_refinements

      RUNTIME_STRING_REFINEMENTS = build_runtime_string_refinements
      private_constant :RUNTIME_STRING_REFINEMENTS

      # --- public API ---------------------------------------------------

      # @param name [String] unqualified constant name (e.g. `"Math::PI"`,
      #   `"RUBY_VERSION"`, `"Ruby::ENGINE"`)
      # @return [Rigor::Type, nil] refined type, or nil to fall through
      def self.lookup(name)
        FOLDED_CONSTANTS[name] || RUNTIME_STRING_REFINEMENTS[name]
      end
    end
  end
end
