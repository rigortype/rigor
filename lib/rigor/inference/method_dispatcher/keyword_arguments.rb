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
        # member (#1737). Only a key that discriminates between `method_types` ({.discriminating?}) splits (#1779):
        # every overload reads any other key's members alike, so splitting it only multiplies the lists toward the
        # limit (`(a: Symbol, b: Symbol)` with two three-member values made nine). An overload that declares no
        # keywords but may take the hash as a positional `Hash` ({.positional_hash_reader?}, whose block says whether
        # a positional parameter may accept a `Hash`) reads every value against that parameter, so then every union
        # value splits. Without a keyword hash, or with no discriminating union value, the one list, `arg_types`
        # itself.
        def distributions(arg_types, keywords_last, method_types, &hash_param)
          keywords = keywords_last && arg_types.last
          return [arg_types] unless keywords.is_a?(Type::HashShape)

          choices = split_choices(keywords, method_types) do
            hash_param && positional_hash_reader?(method_types, arg_types.size, &hash_param)
          end
          return [arg_types] if choices.nil?
          return nil if choices.reduce(1) { |count, (_, members)| count * members.size } > DISTRIBUTION_LIMIT

          combinations(choices).map do |pairs|
            shape = Type::HashShape.new(
              pairs, required_keys: keywords.required_keys, optional_keys: keywords.optional_keys,
                     read_only_keys: keywords.read_only_keys, extra_keys: keywords.extra_keys
            )
            arg_types[0...-1] + [shape]
          end
        end

        # Each key of `keywords` with the values its lists take: a discriminating union value's members, any other
        # value whole. Nil when no value splits. The block answers whether every union value splits (read once).
        def split_choices(keywords, method_types)
          split = false
          every = nil
          choices = keywords.pairs.map do |name, value|
            members = union_members(value)
            next [name, [value]] unless members

            unless discriminating?(name, method_types)
              every = yield ? true : false if every.nil?
              next [name, [value]] unless every
            end

            split = true
            [name, members]
          end
          choices if split
        end

        # Whether the members of `name`'s value may select different overloads among `method_types`: the overloads
        # that take the key (by name or through `**rest`) declare it with different types (`headers: true` in one,
        # `?headers: false` in another). Where they all declare one type, a member it rejects is rejected by every
        # overload, so the split only adds lists: four `flag: bool` keywords alone made sixteen. An overload that
        # declares others but not this key rejects it whatever its value. One that declares no keywords reads the
        # hash positionally, which {.positional_hash_reader?} decides for every key at once.
        def discriminating?(name, method_types)
          first = nil
          method_types.any? do |method_type|
            fun = method_type.type
            next false unless declares?(fun)

            type = (fun.required_keywords[name] || fun.optional_keywords[name] || fun.rest_keywords)&.type
            next false if type.nil?

            first ||= type
            type != first
          end
        end

        # Whether an overload of `method_types` that declares no keywords takes `count` arguments and may read the last,
        # the keyword hash, as a positional `Hash`: the block answers for the RBS parameter at that position (the
        # `(String)` of `(a: Symbol) | (String)` cannot take one, the `(Hash[Symbol, String])` of
        # `(a: Integer) | (Hash[Symbol, String])` can, and its members then select per value), and an untyped `(?)`
        # parameter list may take anything.
        def positional_hash_reader?(method_types, count)
          method_types.any? do |method_type|
            fun = method_type.type
            next false if declares?(fun)
            next true unless fun.respond_to?(:required_positionals)

            param = positional_param_at(fun, count, count - 1)
            !param.nil? && yield(param)
          end
        end

        # The positional parameter `fun` binds the argument at `index` to when called with `count` arguments, or nil
        # when the count does not fit its arity.
        def positional_param_at(fun, count, index)
          required = fun.required_positionals
          trailing = fun.trailing_positionals
          optional = fun.optional_positionals
          minimum = required.size + trailing.size
          return nil if count < minimum || (fun.rest_positionals.nil? && count > minimum + optional.size)
          return required[index] if index < required.size
          return trailing[index - (count - trailing.size)] if index >= count - trailing.size

          optional[index - required.size] || fun.rest_positionals
        end

        # The members a keyword value splits into: a union's, or those of a `Dynamic` whose static facet is a union,
        # less `nil`, which the #521 join usually carries from an arm no call takes (as `FacetDistribution` reads a
        # facet). One member left stands in for the value (`Dynamic[false | nil]` reads as `false`), since the bare
        # `Dynamic` would gradually match every overload's keyword. A plain union keeps `nil`: there it is a value
        # the call may pass.
        def union_members(value)
          return value.members if value.is_a?(Type::Union)
          return nil unless value.is_a?(Type::Dynamic) && value.static_facet.is_a?(Type::Union)

          members = value.static_facet.members.reject { |member| nil_member?(member) }
          members.empty? ? nil : members
        end

        def nil_member?(member)
          return member.value.nil? if member.is_a?(Type::Constant)

          member.is_a?(Type::Nominal) && member.class_name == "NilClass"
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
