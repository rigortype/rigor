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

        def declares?(fun)
          return false unless fun.respond_to?(:required_keywords)

          !fun.required_keywords.empty? || !fun.optional_keywords.empty? || !fun.rest_keywords.nil?
        end

        # The keyword hash `fun` takes as its keywords, or nil when the call passes none or `fun` declares none.
        def keyword_hash(fun, arg_types, keywords_last)
          return nil unless keywords_last && !arg_types.empty? && declares?(fun)

          arg_types.last
        end

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
