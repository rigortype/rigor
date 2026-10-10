# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # How `OverloadSelector` reads a call's keyword arguments (#1727).
      #
      # A call's arguments reach the selector as one positional list, the keyword hash (`f(a, k: 1)`) typed as its
      # last entry. Only the AST tells it from a braced positional hash (`f(a, { k: 1 })`), so the caller says which
      # it is (`keywords_last`). An overload that declares keywords takes that hash as its keywords; one that
      # declares none reads it as a trailing positional `Hash`, as Ruby passes it.
      module KeywordArguments
        NO_PARAMS = [].freeze
        private_constant :NO_PARAMS

        # The most argument lists {.distributions} spells out; past it, the block probe answers no information.
        DISTRIBUTION_LIMIT = 8
        private_constant :DISTRIBUTION_LIMIT

        module_function

        # The actuals `method_type`'s positional parameters read: every argument, less the trailing keyword hash
        # when the call passes one and the overload declares keywords to take it.
        def positional(method_type, arg_types, keywords_last)
          return arg_types unless keywords_last && !arg_types.empty? && declares?(method_type.type)

          arg_types[0...-1]
        end

        # {.positional} for the selector's `shared` bundle, computed once per selection: every overload that takes the
        # keyword hash reads the same trimmed list. A bundle rebuilt with other arguments must reset the cache.
        def selection_positional(method_type, shared)
          return shared[:arg_types] unless shared[:keywords_last] && declares?(method_type.type)

          shared[:positional_arguments] ||= positional(method_type, shared[:arg_types], true)
        end

        # The argument lists a call with a keyword hash stands for, one per combination of the members of its
        # union-typed keyword values (`headers: bool` stands for `headers: true` and `headers: false`, and so does a
        # `Dynamic[bool]`, which the #521 join produces), or nil when that is more than {DISTRIBUTION_LIMIT} lists. A
        # precise union value selects per member at runtime, so an answer that holds for the call must hold for every
        # member (#1737). Without a keyword hash, or with no union value, the one list.
        def distributions(arg_types, keywords_last)
          keywords = keywords_last && arg_types.last
          return [arg_types] unless keywords.is_a?(Type::HashShape)
          return [arg_types] if keywords.pairs.each_value.none? { |value| union_members(value) }

          choices = keywords.pairs.map { |name, value| [name, union_members(value) || [value]] }
          return nil if choices.reduce(1) { |count, (_, members)| count * members.size } > DISTRIBUTION_LIMIT

          combinations(choices).map do |pairs|
            shape = Type::HashShape.new(
              pairs, required_keys: keywords.required_keys, optional_keys: keywords.optional_keys,
                     read_only_keys: keywords.read_only_keys, extra_keys: keywords.extra_keys
            )
            arg_types[0...-1] + [shape]
          end
        end

        # The members a keyword value splits into: a union's, or a `Dynamic` whose static facet is a union's.
        def union_members(value)
          value = value.static_facet if value.is_a?(Type::Dynamic)
          value.members if value.is_a?(Type::Union)
        end

        def combinations(choices)
          choices.reduce([{}]) do |partials, (name, members)|
            partials.flat_map { |partial| members.map { |member| partial.merge(name => member) } }
          end
        end

        def declares?(fun)
          return false unless fun.respond_to?(:required_keywords)

          !fun.required_keywords.empty? || !fun.optional_keywords.empty? || !fun.rest_keywords.nil?
        end

        # The keyword hash `fun` takes as its keywords, or nil when the call passes none or `fun` declares none.
        def keyword_hash(fun, arg_types, keywords_last)
          return nil unless keywords_last && !arg_types.empty? && declares?(fun)

          arg_types.last
        end

        # {.accepted?} for the selector's `shared` bundle: the keyword hash `fun` takes, if any, against its keywords.
        def accepted_by?(fun, shared, strict, &)
          accepted?(fun, keyword_hash(fun, shared[:arg_types], shared[:keywords_last]), strict, &)
        end

        def any_declares?(method_types) = method_types.any? { |method_type| declares?(method_type.type) }

        # Whether `fun`'s keywords take `keywords` (nil for a call without a keyword hash). Without one, an
        # overload that requires a keyword is not viable. With one, a closed shape must carry every required
        # keyword, and every key it carries must be declared (or taken by `**rest`) with a value the block accepts
        # against the declaration. An unshaped keyword hash (`f(**opts)` over a `Hash`) or a shape that may lack a
        # required key is a gradual match only, never a strict one.
        #
        # @yieldparam param — the keyword's `RBS::Types::Function::Param`.
        # @yieldparam value — the type the call passes for it.
        def accepted?(fun, keywords, strict)
          return true unless fun.respond_to?(:required_keywords)
          return fun.required_keywords.empty? if keywords.nil?
          return !strict unless keywords.is_a?(Type::HashShape)

          required_present?(fun, keywords, strict) &&
            keywords.pairs.all? do |name, value|
              param = fun.required_keywords[name] || fun.optional_keywords[name] || fun.rest_keywords
              !param.nil? && yield(param, value)
            end
        end

        # The declarations the keys of the call's keyword hash land in, for the selector's `shared` bundle; empty
        # without a shaped keyword hash `fun` takes (a key nothing declares lands nowhere).
        def passed_params(fun, shared)
          keywords = keyword_hash(fun, shared[:arg_types], shared[:keywords_last])
          return NO_PARAMS unless keywords.is_a?(Type::HashShape)

          keywords.pairs.each_key.filter_map do |name|
            fun.required_keywords[name] || fun.optional_keywords[name] || fun.rest_keywords
          end
        end

        def required_present?(fun, keywords, strict)
          fun.required_keywords.each_key.all? do |name|
            next true if keywords.pairs.key?(name) && !keywords.optional_key?(name)

            # Possibly absent: an optional key, or a key an open shape may carry unseen.
            !strict && (keywords.pairs.key?(name) || keywords.open?)
          end
        end
      end
    end
  end
end
