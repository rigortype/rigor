# frozen_string_literal: true

require_relative "observation_collector"

module Rigor
  module SigGen
    # `--params=observed` member types for a `Data.define` / `Struct.new` class (#1150, #1183): which observed
    # argument reached which member. {ObservationCollector} keys `P.new(...)` under `[class_name, :initialize]`,
    # `P[...]` under `[class_name, ObservationCollector::BRACKET_NEW]`, and every other call on an instance under its
    # own name, so `p.with(...)` and `s.a = v` arrive as `[class_name, :with]` and `[class_name, :a=]`.
    #
    # Each call site is mapped the way the runtime maps it, and a site the runtime would reject, or whose mapping
    # depends on what it does not show, contributes nothing:
    #
    # - A construction passes keywords only or positionals only. Keywords name their member. Positionals feed the
    #   members by index — for `Data` only at the full member count (any other arity raises), for a `Struct` at up
    #   to the member count. A construction mixing the two, or longer than the member list, says nothing.
    # - A `Struct` member a construction leaves out is `nil`, so that site contributes `nil` to it. A `Data`
    #   construction cannot leave one out.
    # - `Data#with(**kw)` contributes each keyword it passes; the members it leaves out keep the receiver's value.
    # - A `Struct` writer call `s.a = v` contributes `v` to `a`.
    # - A splat, a double splat, a block argument or `...` already dropped the whole site in the collector.
    #
    # The caller unions the lists; a member no site reaches is absent from the result and renders `untyped`.
    module MetaMemberObservation
      module_function

      # Each member some site reaches, with the types those sites pass it.
      def types(observations, class_name, kind:, members:)
        out = Hash.new { |hash, member| hash[member] = [] }
        constructions(observations, class_name).each { |call| record_construction(out, call, kind, members) }
        if kind == :data
          observations.fetch([class_name, :with], []).each { |call| record_with(out, call, members) }
        else
          members.each do |member|
            observations.fetch([class_name, :"#{member}="], []).each do |call|
              out[member] << call.positional.first if call.positional.size == 1 && call.keyword.empty?
            end
          end
        end
        out.reject { |_, list| list.empty? }
      end

      def constructions(observations, class_name)
        observations.fetch([class_name, :initialize], []) +
          observations.fetch([class_name, ObservationCollector::BRACKET_NEW], [])
      end

      def record_construction(out, call, kind, members)
        if call.positional.empty?
          record_keywords(out, call.keyword, kind, members)
        elsif call.keyword.empty?
          record_positionals(out, call.positional, kind, members)
        end
      end

      def record_keywords(out, keyword, kind, members)
        return unless (keyword.keys - members).empty?

        members.each do |member|
          if keyword.key?(member)
            out[member] << keyword[member]
          elsif kind == :struct
            out[member] << Type::Combinator.constant_of(nil)
          end
        end
      end

      def record_positionals(out, positional, kind, members)
        return if positional.size > members.size
        return if kind == :data && positional.size != members.size

        members.each_with_index do |member, index|
          out[member] << (index < positional.size ? positional[index] : Type::Combinator.constant_of(nil))
        end
      end

      def record_with(out, call, members)
        return unless call.positional.empty? && (call.keyword.keys - members).empty?

        call.keyword.each { |member, type| out[member] << type }
      end
    end
  end
end
