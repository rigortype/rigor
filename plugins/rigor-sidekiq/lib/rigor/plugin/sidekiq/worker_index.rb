# frozen_string_literal: true

module Rigor
  module Plugin
    class Sidekiq < Rigor::Plugin::Base
      # Frozen catalogue of discovered Sidekiq worker classes keyed by qualified class name. Each entry
      # holds the `#perform` method's arity envelope so the analyzer can validate
      # `Worker.perform_async(...)` call sites.
      #
      # Uses the same `min_arity` / `max_arity` closed-range envelope as `rigor-activejob`'s
      # `JobIndex::Entry` (`Float::INFINITY` upper bound when `*args` is present); Sidekiq workers
      # serialize args to JSON so keyword arity is not tracked here.
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

        # `entries` is expected UNIQUE by `class_name`: the by-name Hash is keyed by it, so a second row for
        # a worker would replace the first outright. {WorkerDiscoverer#merge_redeclarations} is the single
        # home of that guarantee — a reopened class arrives as one merged row, never as two.
        def initialize(entries)
          @entries = entries.freeze
          @by_name = entries.to_h { |entry| [entry.class_name, entry] }.freeze
          freeze
        end

        # Entries are keyed by the de-rooted constant path (`"WelcomeWorker"`, `"Admin::WelcomeWorker"` —
        # never `"::WelcomeWorker"`; see {WorkerDiscoverer}), while a QUERY may legitimately arrive rooted:
        # `::WelcomeWorker.perform_async(1)` renders its receiver as `"::WelcomeWorker"`. The root marker is
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

        # `::WelcomeWorker` → `WelcomeWorker`. The query-side half of the key contract — see {#find}.
        def strip_leading_namespace(name) = name.delete_prefix("::")
      end
    end
  end
end
