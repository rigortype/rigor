# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"

module Rigor
  module Inference
    # ADR-47 WD5 — decides the arm of a **version guard**: an `if` / `unless` predicate that compares the
    # Ruby (or a bundled default gem's) version against a literal, both sides readable at analysis time.
    #
    # Multi-version gems select an API generation with these guards routinely:
    #
    #     if Gem::Version.new(Psych::VERSION) >= Gem::Version.new("3.1.0.pre1")
    #       ::YAML.safe_load(yaml, permitted_classes: permitted_classes)
    #     else
    #       ::YAML.safe_load(yaml, permitted_classes)   # Psych < 3.1 positional form
    #     end
    #
    # The dead arm is honest code for an older Ruby, but it never runs on the Ruby the user is checking
    # with — so a diagnostic inside it is a false positive ("the program works" outranks the worst-case
    # static reading, issue #627). {.verdict} answers `:truthy` / `:falsey` for a decidable guard, and
    # `StatementEvaluator#eval_if` / `#eval_unless` then take the *exact* path they already take for
    # `if false`: only the live arm is evaluated, so the dead arm contributes neither diagnostics nor
    # writes to the post-`if` scope.
    #
    # ## The reference Ruby
    #
    # The version compared against is the **analyzer's own** `RUBY_VERSION` / `RUBY_ENGINE`. That is the
    # premise Rigor already runs on: {Builtins::PredefinedConstantRefinements} resolves these constants
    # through the analyzer's runtime, and the core / stdlib RBS the engine reads is the one shipped with
    # the interpreter running `rigor`. `Configuration#target_ruby` is deliberately NOT consulted — it is a
    # Prism *parse* version (it decides which syntax is accepted), it is not threaded to the inference
    # layer, and its default (`"4.0"`) is a default rather than a user statement about the runtime.
    #
    # ## What is folded (and what is deliberately not)
    #
    # * `RUBY_VERSION <cmp> "x.y.z"` — compared with **String** semantics, because that is what runs.
    #   Ruby compares strings lexically, so `RUBY_VERSION >= "3.10"` is famously false on 3.10; folding
    #   with String semantics reproduces the program's real behaviour rather than an idealised one.
    # * `Gem::Version.new(a) <cmp> Gem::Version.new(b)` — both sides wrapped, compared with
    #   `Gem::Version` semantics. A *mixed* comparison (one side wrapped, the other a bare String) is
    #   never folded: `Gem::Version#<=>` returns nil for a non-Version operand, so `Comparable` raises at
    #   runtime and there is no arm to pick.
    # * `RUBY_ENGINE == / != "…"` — equality only. An *ordering* comparison on an engine name is not a
    #   version guard, so it is left alone.
    # * `X::VERSION` — only for the curated {VERSION_CONSTANTS} set: constants of **default gems shipped
    #   with the running Ruby**, where "the analyzer's Ruby is the target's Ruby" already covers them.
    #   A third-party gem's `VERSION` is not read: its version is the project's `Gemfile.lock`'s to say,
    #   and the lockfile is not visible from the inference layer.
    # * `RUBY_PLATFORM` — **never** folded. Every comparison against it is by construction
    #   platform-dependent, and the machine running `rigor` need not be the machine running the program.
    # * `<=>` — never folded (it yields -1/0/1, not a branch verdict), and neither are `defined?(Ractor)`
    #   style capability probes, `!` / `&&` / `||` compositions, or `case` subjects. Each would need its
    #   own argument; an unfoldable guard simply keeps both arms live, which is the pre-existing
    #   behaviour.
    # * Two bare String literals (`if "a" < "b"`) — declined. That is a constant comparison, not a version
    #   guard; the existing constant-fold tier already answers it, and widening this rule to cover it would
    #   buy scope without buying an FP fix. At least one side must be a readable constant or a
    #   `Gem::Version`.
    module VersionGuard
      module_function

      # Comparison operators whose result is a branch verdict. `<=>` is excluded on purpose.
      ORDERING = Set[:<, :<=, :>, :>=].freeze
      EQUALITY = Set[:==, :!=].freeze
      private_constant :ORDERING, :EQUALITY

      # Predefined constants read from the analyzer's runtime, mapped to the operand kind they produce.
      # `:string` operands accept every comparison; `:engine` operands accept equality only.
      PREDEFINED = { RUBY_VERSION: :string, RUBY_ENGINE: :engine }.freeze
      private_constant :PREDEFINED

      # Operand kinds that carry a plain Ruby String, i.e. the ones `Gem::Version.new` may wrap and the
      # ones that compare with each other.
      STRING_KINDS = Set[:literal_string, :string, :engine].freeze
      private_constant :STRING_KINDS

      # Qualified `X::VERSION` constants that may be read from the analyzer's runtime.
      #
      # Admission criterion: the constant belongs to a **default gem of the running Ruby**, so its value
      # is fixed by the same interpreter choice that already fixes `RUBY_VERSION` and the core RBS. Add an
      # entry only when that holds; a gem the project resolves through its own `Gemfile.lock` does not
      # qualify, because the analyzer's copy and the project's can differ.
      VERSION_CONSTANTS = Set["Psych::VERSION"].freeze
      private_constant :VERSION_CONSTANTS

      GEM_VERSION_PATH = "Gem::Version"
      private_constant :GEM_VERSION_PATH

      # @rbs node: Prism::Node? -- An `if` / `unless` predicate
      # @rbs return: Symbol? --
      #   `:truthy` / `:falsey` when the guard is decidable on the analyzer's Ruby, otherwise nil (both arms stay
      #   live)
      def verdict(node)
        return nil unless node.is_a?(Prism::CallNode)

        operator = node.name
        return nil unless ORDERING.include?(operator) || EQUALITY.include?(operator)
        return nil if node.block || node.receiver.nil?

        arguments = node.arguments&.arguments
        return nil unless arguments && arguments.length == 1

        left = read_operand(node.receiver)
        right = read_operand(arguments.first)
        return nil if left.nil? || right.nil?

        decide(left, right, operator)
      end

      # Reads one side of the comparison into `[kind, value]`, or nil when it is not readable.
      #
      # @rbs return: [Symbol, untyped]?
      def read_operand(node)
        case node
        when Prism::StringNode then [:literal_string, node.unescaped]
        when Prism::ConstantReadNode then read_predefined(node)
        when Prism::ConstantPathNode then read_version_constant(node)
        when Prism::CallNode then read_gem_version(node)
        end
      end
      private_class_method :read_operand

      def read_predefined(node)
        kind = PREDEFINED[node.name]
        return nil unless kind

        value = runtime_value(node.name.to_s)
        value && [kind, value]
      end
      private_class_method :read_predefined

      def read_version_constant(node)
        path = Source::ConstantPath.qualified_name_or_nil(node)
        return nil unless path && VERSION_CONSTANTS.include?(path)

        value = runtime_value(path)
        value && [:string, value]
      end
      private_class_method :read_version_constant

      # `Gem::Version.new(<readable>)`. The inner operand must be a plain version String — an engine name
      # is not a version, and `Gem::Version.new` raises on anything `Gem::Version.correct?` rejects, so a
      # malformed literal keeps both arms live instead of folding a guard the program cannot even reach.
      def read_gem_version(node)
        return nil unless node.name == :new && node.block.nil?
        return nil unless Source::ConstantPath.qualified_name_or_nil(node.receiver) == GEM_VERSION_PATH

        arguments = node.arguments&.arguments
        return nil unless arguments && arguments.length == 1

        inner = read_operand(arguments.first)
        return nil unless inner && STRING_KINDS.include?(inner.first)
        return nil unless ::Gem::Version.correct?(inner.last)

        [:gem_version, ::Gem::Version.new(inner.last)]
      end
      private_class_method :read_gem_version

      # Resolves a constant path in the analyzer's own runtime without triggering `const_missing` or an
      # autoload. The path is always one of {PREDEFINED} / {VERSION_CONSTANTS} — Rigor's own source,
      # never a name read out of the analysed program — but the walk is guarded the same way
      # {Builtins::PredefinedConstantRefinements} is, for the same reason: `const_defined?` answers true
      # for a REGISTERED-BUT-NOT-YET-TRIGGERED autoload, so it does not mean "already in memory" and
      # `const_get` would execute the target file inside the analyzer. `Module#autoload?` is what
      # separates the two ([#680](https://github.com/rigortype/rigor/issues/680)).
      #
      # @rbs return: String? -- The constant's value when it is a non-empty String
      def runtime_value(path)
        mod = ::Object
        path.split("::").each do |part|
          return nil unless mod.is_a?(::Module) && mod.const_defined?(part, false)
          return nil if mod.autoload?(part)

          mod = mod.const_get(part, false)
        end

        mod.is_a?(::String) && !mod.empty? ? mod : nil
      rescue ::StandardError, ::ScriptError, ::SystemExit
        # Wider than `NameError` / `TypeError` / `LoadError`: folding a version guard is a precision
        # win, and nothing it can hit justifies stopping the run. `SystemExit` is not a `StandardError`
        # and escaped every rescue in the analyzer when a resolution executed third-party code (#680).
        # `Interrupt`, `SignalException` and `NoMemoryError` stay uncaught on purpose.
        nil
      end
      private_class_method :runtime_value

      # Applies the operator with the semantics that actually run. Operands must be the same kind, and an
      # engine name only ever answers equality.
      def decide(left, right, operator)
        left_kind, left_value = left
        right_kind, right_value = right
        return nil unless comparable_kinds?(left_kind, right_kind)
        return nil if (left_kind == :engine || right_kind == :engine) && !EQUALITY.include?(operator)

        result = apply(left_value, right_value, operator)
        return nil if result.nil?

        result ? :truthy : :falsey
      end
      private_class_method :decide

      # `:gem_version` only ever compares with another `:gem_version` — `Gem::Version#<=>` answers nil for
      # a String operand, so the mixed spelling raises at runtime and has no live arm to pick. The String
      # kinds compare with each other, EXCEPT two bare literals: that is a constant comparison, not a
      # version guard.
      def comparable_kinds?(left_kind, right_kind)
        return left_kind == right_kind if left_kind == :gem_version || right_kind == :gem_version

        !(left_kind == :literal_string && right_kind == :literal_string)
      end
      private_class_method :comparable_kinds?

      def apply(left, right, operator)
        case operator
        when :<  then left < right
        when :<= then left <= right
        when :>  then left > right
        when :>= then left >= right
        when :== then left == right
        when :!= then left != right
        end
      rescue ::ArgumentError, ::TypeError, ::NoMethodError
        nil
      end
      private_class_method :apply
    end
  end
end
