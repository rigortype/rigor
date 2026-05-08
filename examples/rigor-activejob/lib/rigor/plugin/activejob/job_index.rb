# frozen_string_literal: true

module Rigor
  module Plugin
    class Activejob < Rigor::Plugin::Base
      # Frozen catalogue of discovered ActiveJob subclasses
      # keyed by qualified class name. Each entry holds the
      # `#perform` method's arity envelope so the analyzer can
      # validate `Job.perform_later(...)` call sites.
      #
      # `min_arity` / `max_arity` form a closed range
      # (`Float::INFINITY` for the upper bound when `*args`
      # is present). `keyword_required` lists any required
      # keyword arguments — Active Job supports keyword args
      # but they're rare in user code, so the analyzer only
      # validates positional arity for v0.1.0.
      class JobIndex
        Entry = Data.define(:class_name, :min_arity, :max_arity, :keyword_required) do
          # Flexible-friendly textual form of the arity for
          # error messages: `1`, `1..2`, `2+`.
          def arity_label
            return "#{min_arity}+" if max_arity == Float::INFINITY
            return min_arity.to_s if min_arity == max_arity

            "#{min_arity}..#{max_arity}"
          end

          # Predicate for the analyzer's wrong-arity check.
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
