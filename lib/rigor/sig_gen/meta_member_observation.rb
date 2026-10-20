# frozen_string_literal: true

require_relative "observation_collector"

module Rigor
  module SigGen
    # `--params=observed` member types for a `Data.define` / `Struct.new` class (#1150, #1183): which observed
    # argument reached which member. {ObservationCollector} keys `P.new(...)` under `[class_name, :initialize]`,
    # `P[...]` under `[class_name, ObservationCollector::BRACKET_NEW]`, and every other call on an instance under its
    # own name, so `p.with(...)`, `s.a = v`, `s[:a] = v` and `s.send(:a=, v)` arrive under `:with`, `:a=`, `:[]=` and
    # `:send`.
    #
    # The proposal must never be narrower than a value the program stores, so a site is either mapped the way the
    # runtime maps it, or, when it may write a member through a mapping it does not show, it makes that member
    # `untyped`. Only a site the runtime would reject (`ArgumentError`) contributes nothing.
    #
    # - A construction passing only keywords names its members when the class takes keywords: a `Data`, a Struct
    #   with `keyword_init: true`, or a Struct whose `keyword_init:` is absent on Ruby 3.2 and later. On any other
    #   Struct the keywords may become a Hash in the first member, so the site keeps every member `untyped`.
    # - A construction passing only positionals feeds the members by index: for a `Data` only at the full member
    #   count, for a Struct at up to the member count, and never on a `keyword_init: true` Struct.
    # - A construction mixing positionals and keywords keeps every member `untyped`.
    # - A Struct member a construction leaves out is `nil`. A member only ever left out stays `untyped`, not `nil`.
    # - `Data#with(**kw)` contributes each keyword it passes.
    # - A Struct writer call `s.a = v` contributes `v`. `s[key] = v` and `s.send(:a=, v)` keep the member they name
    #   `untyped` (every member, for a key or a method name that is not a literal).
    # - {ObservationCollector::UNMAPPED} entries (a splat, an operator or multiple-assignment write, a writer on a
    #   receiver typed as no one class, a class {ValueClassEligibility} finds ineligible) keep the members they name
    #   `untyped`.
    #
    # The caller unions the lists; a member no site reaches is absent from the result and renders `untyped`.
    module MetaMemberObservation
      SEND_NAMES = %i[send public_send __send__].freeze
      OMITTED = :omitted
      private_constant :SEND_NAMES, :OMITTED

      module_function

      # Each member some site reaches, with the types those sites pass it. `keywords` is how the class reads a
      # keyword-only construction: `:members` (by name) or `:hash` (possibly as a Hash in the first member, so every
      # member is tainted). `positionals: false` marks a class that rejects a positional construction
      # (`keyword_init: true`).
      def types(observations, class_name, kind:, members:, keywords: :members, positionals: true)
        out = Hash.new { |hash, member| hash[member] = [] }
        context = { out: out, kind: kind, members: members, keywords: keywords, positionals: positionals }
        constructions(observations, class_name).each { |call| record_construction(context, call) }
        if kind == :data
          record_withs(context, observations, class_name)
        else
          record_writers(context, observations, class_name)
        end
        record_unmapped(context, observations.fetch([class_name, ObservationCollector::UNMAPPED], []) +
                                 observations.fetch([ObservationCollector::ANY_CLASS, ObservationCollector::UNMAPPED], []))
        finish(out)
      end

      def constructions(observations, class_name)
        observations.fetch([class_name, :initialize], []) +
          observations.fetch([class_name, ObservationCollector::BRACKET_NEW], [])
      end

      def record_construction(context, call)
        if call.positional.empty?
          record_keywords(context, call.keyword)
        elsif call.keyword.empty?
          record_positionals(context, call.positional) if context[:positionals]
        else
          taint_all(context)
        end
      end

      def record_keywords(context, keyword)
        return taint_all(context) if context[:keywords] == :hash

        members = context[:members]
        return unless (keyword.keys - members).empty?

        members.each do |member|
          if keyword.key?(member)
            context[:out][member] << keyword[member]
          elsif context[:kind] == :struct
            context[:out][member] << OMITTED
          end
        end
      end

      def record_positionals(context, positional)
        members = context[:members]
        return if positional.size > members.size
        return if context[:kind] == :data && positional.size != members.size

        members.each_with_index do |member, index|
          context[:out][member] << (index < positional.size ? positional[index] : OMITTED)
        end
      end

      def record_withs(context, observations, class_name)
        observations.fetch([class_name, :with], []).each do |call|
          next unless call.positional.empty? && (call.keyword.keys - context[:members]).empty?

          call.keyword.each { |member, type| context[:out][member] << type }
        end
      end

      def record_writers(context, observations, class_name)
        members = context[:members]
        members.each do |member|
          observations.fetch([class_name, :"#{member}="], []).each do |call|
            context[:out][member] << call.positional.first if call.positional.size == 1 && call.keyword.empty?
          end
        end
        observations.fetch([class_name, :[]=], []).each { |call| taint(context, index_member(call, members)) }
        SEND_NAMES.each do |name|
          observations.fetch([class_name, name], []).each { |call| taint(context, sent_member(call)) }
        end
      end

      # The member `s[key] = v` writes: a literal Symbol / String key names it, a literal Integer indexes it, and any
      # other key may be every member.
      def index_member(call, members)
        key = call.positional.first
        return ObservationCollector::ALL_MEMBERS unless key.is_a?(Type::Constant)

        case key.value
        when Symbol, String then key.value.to_sym
        when Integer then members[key.value] || ObservationCollector::ALL_MEMBERS
        else ObservationCollector::ALL_MEMBERS
        end
      end

      # The member `s.send(name, ...)` may write: the writer a literal name spells, none for a literal non-writer, and
      # every member for `[]=` or a name that is not a literal.
      def sent_member(call)
        name = call.positional.first
        return ObservationCollector::ALL_MEMBERS unless name.is_a?(Type::Constant)
        return ObservationCollector::ALL_MEMBERS unless name.value.is_a?(Symbol) || name.value.is_a?(String)

        spelled = name.value.to_s
        return ObservationCollector::ALL_MEMBERS if spelled == "[]="
        return spelled.delete_suffix("=").to_sym if spelled.match?(/\A\w+=\z/)

        nil
      end

      def record_unmapped(context, calls)
        calls.each { |call| call.keyword.each_key { |member| taint(context, member) } }
      end

      def taint(context, member)
        return if member.nil?
        return taint_all(context) if member == ObservationCollector::ALL_MEMBERS

        context[:out][member] << Type::Combinator.untyped if context[:members].include?(member)
      end

      def taint_all(context)
        context[:members].each { |member| context[:out][member] << Type::Combinator.untyped }
      end

      # A member only ever left out has no observed value, so it is dropped; beside any other value an omission is
      # `nil`.
      def finish(out)
        out.filter_map do |member, list|
          next if list.all?(OMITTED)

          [member, list.map { |type| OMITTED.equal?(type) ? Type::Combinator.constant_of(nil) : type }]
        end.to_h
      end
    end
  end
end
