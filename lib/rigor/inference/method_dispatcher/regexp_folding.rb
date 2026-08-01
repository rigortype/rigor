# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `Regexp` class-method calls on statically known arguments.
      #
      # === Supported methods
      #
      # * `escape(str)` / `quote(str)` — escapes regexp meta-characters. Returns `Constant[String]`.
      # * `new(str)` / `new(str, opts)` — constructs a Regexp at fold time when the pattern argument is a
      #   `Constant[String]`. The optional second argument may be a `Constant[Integer]` (flag bits), a
      #   `Constant[true/false]` (IGNORECASE shorthand), or absent. Returns `Constant[Regexp]`.
      # * `compile(str)` / `compile(str, opts)` — `Regexp.compile` is a documented alias of `Regexp.new`
      #   (same C entry point, `rb_reg_s_new`); shares `fold_new` verbatim.
      #
      # === Non-constant / unsupported cases
      #
      # Returns `nil` (deferring to the next dispatcher tier) when:
      # - the receiver is not `Singleton[Regexp]`,
      # - the required pattern argument is not a `Constant[String]`,
      # - the method is not in the supported set.
      module RegexpFolding
        REGEXP_ESCAPE_METHODS = Set[:escape, :quote].freeze
        private_constant :REGEXP_ESCAPE_METHODS

        # `.new` and `.compile` are the same C function under two names — both fold identically.
        REGEXP_NEW_METHODS = Set[:new, :compile].freeze
        private_constant :REGEXP_NEW_METHODS

        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer.
        def try_dispatch(context)
          receiver = context.receiver
          method_name = context.method_name
          args = context.args
          return nil unless SingletonFolding.receiver?(receiver, "Regexp")
          return fold_escape(args) if REGEXP_ESCAPE_METHODS.include?(method_name)
          return fold_new(args) if REGEXP_NEW_METHODS.include?(method_name)
          return fold_last_match(context) if method_name == :last_match

          nil
        end

        # `Regexp.last_match` reads the same match-data slot the perlish `$~` global tracks. On a
        # proven-match edge — the truthy branch of `if str =~ /re/`, the surviving path of `unless /re/ =~
        # s; raise; end`, a `case`/`when` regex arm — the flow engine has already narrowed `$~` to a
        # non-nil `MatchData` (see `Narrowing#regex_match_predicate_scopes`). Upstream RBS types
        # `Regexp.last_match` as `() -> MatchData?` / `(int) -> String?`, so without this consult the call
        # drops back to the nilable return even where the surrounding flow has *proven* the match
        # succeeded — re-introducing the `possible nil receiver` the `$~` narrowing exists to remove the
        # moment the code reaches for the match through the method rather than the global.
        #
        # Mirrors the global's narrowing exactly, so it rides the same `Scope#forget_match_globals`
        # invalidation (an intervening call that can re-run a match clears `$~`, and this consult clears
        # with it):
        #
        # * 0-arg  -> `MatchData` (the narrowed `$~`)
        # * `(N)`  -> `String` when capture group N is unconditional on every successful match (the same
        #             set the `$N` globals narrow), else `String?` (an optional / alternation-reachable
        #             group is nil at runtime even on a successful match).
        # * `(:name)` / `(0)` and other forms defer to RBS.
        #
        # Declines (returns nil -> RBS) whenever `$~` is NOT proven non-nil: no match edge established it,
        # or a falsey edge bound it to `Constant[nil]`. Narrowing only on the proven edge keeps the bare
        # `m = Regexp.last_match; m[...]` (no preceding match) firing exactly as today — this never invents
        # a match.
        def fold_last_match(context)
          scope = context.scope
          return nil if scope.nil?

          match_data = scope.global(:$~)
          return nil unless proven_match?(match_data)

          args = context.args
          return Type::Combinator.nominal_of("MatchData") if args.empty?
          return nil unless args.size == 1

          fold_last_match_group(args.first, scope)
        end

        # Narrowed `$~` is a non-nil `Nominal[MatchData]`. A bare `MatchData?` / `nil` / Dynamic binding is
        # NOT a proven match.
        def proven_match?(match_data)
          match_data.is_a?(Type::Nominal) && match_data.class_name == "MatchData"
        end

        # `Regexp.last_match(N)` for a value-pinned positive Integer N. Track the matching `$N` global the
        # predicate edge already narrowed: present (`String`) means the group is unconditional, absent
        # means it is optional / alternation-reachable (nil at runtime on a success), so we surface
        # `String?`. A non-constant or non-positive index defers to RBS.
        def fold_last_match_group(arg, scope)
          return nil unless arg.is_a?(Type::Constant)

          index = arg.value
          return nil unless index.is_a?(Integer) && index.positive?

          string_t = Type::Combinator.nominal_of("String")
          group_global = scope.global(:"$#{index}")
          return string_t if group_global.is_a?(Type::Nominal) && group_global.class_name == "String"

          Type::Combinator.union(string_t, Type::Combinator.constant_of(nil))
        end

        # `Regexp.escape(str)` / `.quote(str)` — one String arg.
        def fold_escape(args)
          return nil unless args.size == 1

          str = SingletonFolding.constant_string(args.first)
          return nil if str.nil?

          Type::Combinator.constant_of(Regexp.escape(str))
        end

        # `Regexp.new(pattern)` / `Regexp.new(pattern, opts)` — constructs the pattern at inference time.
        # Also serves `Regexp.compile`, its documented alias (`REGEXP_NEW_METHODS`). Delegates to Ruby's
        # real `Regexp.new` so all option forms (Integer flags, `true`/`false`, option strings) are handled
        # without case-analysis; non-constant or invalid arguments decline through to the RBS tier.
        def fold_new(args)
          return nil if args.empty? || args.size > 2

          pattern_arg = args.first
          return nil unless pattern_arg.is_a?(Type::Constant) &&
                            pattern_arg.value.is_a?(String)

          opts = args.size == 2 ? constant_value_or_nil(args[1]) : 0
          return nil if args.size == 2 && opts.nil?

          Type::Combinator.constant_of(Regexp.new(pattern_arg.value, opts))
        rescue StandardError
          nil
        end

        def constant_value_or_nil(type)
          type.is_a?(Type::Constant) ? type.value : nil
        end
      end
    end
  end
end
