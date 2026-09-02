# frozen_string_literal: true

module Rigor
  module Plugin
    class Activejob < Rigor::Plugin::Base
      # Frozen catalogue of discovered ActiveJob subclasses keyed by qualified class name. Each entry
      # holds the `#perform` method's arity envelope so the analyzer can validate
      # `Job.perform_later(...)` call sites.
      #
      # `min_arity` / `max_arity` form a closed range (`Float::INFINITY` for the upper bound when
      # `*args` is present). `keyword_required` lists any required keyword arguments — Active Job
      # supports keyword args but they're rare in user code, so the analyzer validates positional arity
      # only (keyword arity validation is deferred).
      class JobIndex
        Entry = Data.define(:class_name, :min_arity, :max_arity, :keyword_required) do
          # Flexible-friendly textual form of the arity for error messages: `1`, `1..2`, `2+`.
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

        # `entries` is expected UNIQUE by `class_name`: the by-name Hash is keyed by it, so a second row for
        # a job would replace the first outright. {JobDiscoverer#merge_redeclarations} is the single home of
        # that guarantee — a reopened class arrives as one merged row, never as two.
        def initialize(entries)
          @entries = entries.freeze
          @by_name = entries.to_h { |entry| [entry.class_name, entry] }.freeze
          freeze
        end

        # Entries are keyed by the de-rooted constant path (`"WelcomeJob"`, `"Admin::WelcomeJob"` — never
        # `"::WelcomeJob"`; see {JobDiscoverer}), while a QUERY may legitimately arrive rooted:
        # `::WelcomeJob.perform_later(1)` renders its receiver as `"::WelcomeJob"`. The root marker is
        # dropped here, once, so no caller needs a `find(name) || find("::#{name}")` retry (#621).
        #
        # @return [Entry, nil]
        def find(class_name)
          @by_name[strip_leading_namespace(class_name.to_s)]
        end

        def known?(class_name)
          @by_name.key?(strip_leading_namespace(class_name.to_s))
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

        private

        # `::WelcomeJob` → `WelcomeJob`. The query-side half of the key contract — see {#find}.
        def strip_leading_namespace(name) = name.delete_prefix("::")
      end
    end
  end
end
