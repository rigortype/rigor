# frozen_string_literal: true

module Rigor
  module Analysis
    # Immutable storage for flow-sensitive facts attached to a Scope snapshot.
    #
    # The first implementation keeps the bucket model deliberately small:
    # callers can record local-binding and relational facts, invalidate all
    # facts that mention a target, and conservatively join two stores by
    # retaining only facts that both incoming edges share.
    class FactStore
      BUCKETS = %i[
        local_binding
        captured_local
        object_content
        global_storage
        dynamic_origin
        relational
      ].freeze

      Target = Data.define(:kind, :name) do
        def self.local(name)
          new(kind: :local, name: name.to_sym)
        end

        def initialize(kind:, name:)
          super(kind: kind.to_sym, name: name)
        end
      end

      Fact = Data.define(:bucket, :target, :predicate, :payload, :polarity, :stability) do
        def initialize(bucket:, target:, predicate:, payload: nil, polarity: :positive, stability: :local_binding)
          bucket = bucket.to_sym
          raise ArgumentError, "unknown fact bucket #{bucket.inspect}" unless BUCKETS.include?(bucket)

          super(
            bucket: bucket,
            target: target,
            predicate: predicate.to_sym,
            payload: payload,
            polarity: polarity.to_sym,
            stability: stability.to_sym
          )
        end
      end

      attr_reader :facts

      class << self
        def empty
          @empty ||= new
        end
      end

      def initialize(facts: [])
        @facts = normalize(facts)
        freeze
      end

      def empty?
        facts.empty?
      end

      def with_fact(fact)
        self.class.new(facts: facts + [fact])
      end

      def with_local_fact(name, predicate:, payload: nil, bucket: :local_binding, polarity: :positive)
        with_fact(
          Fact.new(
            bucket: bucket,
            target: Target.local(name),
            predicate: predicate,
            payload: payload,
            polarity: polarity,
            stability: :local_binding
          )
        )
      end

      def facts_for(target: nil, bucket: nil)
        selected_bucket = bucket&.to_sym
        facts.select do |fact|
          (target.nil? || fact_targets(fact).include?(target)) &&
            (selected_bucket.nil? || fact.bucket == selected_bucket)
        end
      end

      def invalidate_target(target, buckets: nil)
        selected = buckets&.map(&:to_sym)
        kept = facts.reject do |fact|
          fact_targets(fact).include?(target) && (selected.nil? || selected.include?(fact.bucket))
        end
        return self if kept == facts

        self.class.new(facts: kept)
      end

      def join(other)
        unless other.is_a?(FactStore)
          raise ArgumentError, "join requires a Rigor::Analysis::FactStore, got #{other.class}"
        end

        self.class.new(facts: facts.select { |fact| other.facts.include?(fact) })
      end

      def ==(other)
        other.is_a?(FactStore) && facts == other.facts
      end
      alias eql? ==

      def hash
        [FactStore, facts].hash
      end

      private

      def normalize(raw_facts)
        unique = []
        raw_facts.each do |fact|
          raise ArgumentError, "expected Rigor::Analysis::FactStore::Fact, got #{fact.class}" unless fact.is_a?(Fact)

          unique << fact unless unique.include?(fact)
        end
        unique.freeze
      end

      def fact_targets(fact)
        Array(fact.target)
      end
    end
  end
end
