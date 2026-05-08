# frozen_string_literal: true

module Rigor
  module Plugin
    class Sidekiq < Rigor::Plugin::Base
      # Frozen catalogue of discovered Sidekiq worker
      # classes keyed by qualified class name. Each entry
      # holds the `#perform` method's arity envelope so the
      # analyzer can validate `Worker.perform_async(...)`
      # call sites.
      #
      # Same envelope shape as `rigor-activejob`'s
      # `JobIndex::Entry`: `min_arity` / `max_arity` form a
      # closed range (`Float::INFINITY` for the upper bound
      # when `*args` is present).
      class WorkerIndex
        Entry = Data.define(:class_name, :min_arity, :max_arity) do
          def arity_label
            return "#{min_arity}+" if max_arity == Float::INFINITY
            return min_arity.to_s if min_arity == max_arity

            "#{min_arity}..#{max_arity}"
          end

          def accepts?(actual)
            actual.between?(min_arity, max_arity)
          end
        end

        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          @by_name = entries.to_h { |entry| [entry.class_name, entry] }.freeze
          freeze
        end

        # @return [Entry, nil]
        def find(class_name)
          @by_name[class_name.to_s]
        end

        def known?(class_name)
          @by_name.key?(class_name.to_s)
        end

        def empty?
          @entries.empty?
        end

        def size
          @entries.size
        end

        def names
          @by_name.keys
        end
      end
    end
  end
end
