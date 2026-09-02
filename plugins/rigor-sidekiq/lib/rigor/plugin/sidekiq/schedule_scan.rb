# frozen_string_literal: true

require "yaml"

module Rigor
  module Plugin
    class Sidekiq < Rigor::Plugin::Base
      # ADR-102 WD3 / #367 — which workers does this project enqueue by NAME, from schedule configuration?
      #
      # This is the one genuinely Sidekiq-specific reachability root, and the reason it is worth reading YAML
      # for: a cron-scheduled worker is enqueued from `config/schedule.yml` as the string `"HardWorker"`, so
      # the repository may contain no `HardWorker.perform_async` anywhere. The constant scan sees nothing, and
      # `rigor unused` reports a worker that runs every night as dead code.
      #
      # Two layouts, one key. `sidekiq-cron` writes the schedule as the whole document
      # (`{ name => { "cron" =>, "class" => } }`); `sidekiq-scheduler` nests the same entries under
      # `config/sidekiq.yml`'s `:scheduler: :schedule:` block. Both name the worker under `class:`, and
      # `class:` is the ONLY key read here.
      #
      # **What this refuses to read is the queue list.** `:queues:` in `sidekiq.yml` holds queue names, and a
      # queue name is not a class name — inflecting `report_worker` into `ReportWorker` would manufacture a
      # root out of a naming coincidence, which is precisely the over-supply this plugin declined in #350. An
      # over-claiming root source silently hides real dead code (ADR-102 § Consequences), and nothing
      # downstream can tell you it happened. So a queue contributes nothing, deliberately.
      #
      # Names are not trusted either: the caller intersects them with the workers {WorkerDiscoverer} actually
      # found, so a typo or an out-of-tree class costs coverage rather than manufacturing a root, and the
      # report's `matched no declaration` counter stays meaningful.
      #
      # Fail-soft throughout, because this reads user-authored config that Rigor does not own: an absent file,
      # an unreadable one, a YAML syntax error, or a document that is not a Hash contributes nothing rather
      # than raising. `rigor unused` is a report a human reads, and refusing to print it because one
      # `sidekiq.yml` has a stray tab is a bad trade.
      class ScheduleScan
        # The key naming the worker, in both layouts. Symbol keys are accepted because `sidekiq.yml` is
        # conventionally written with them (`:scheduler:`, `:schedule:`), and Psych parses `:class:` as the
        # Symbol `:class`.
        CLASS_KEY = "class"

        # Where a schedule block hides inside a document. `[]` is the document itself — `sidekiq-cron`'s
        # `schedule.yml` IS the schedule map — and the nested paths are `sidekiq-scheduler`'s, whose entries
        # live under `:scheduler: :schedule:` (with the bare `:schedule:` form kept for pre-3.0 layouts).
        SCHEDULE_BLOCK_KEY_PATHS = [[], %w[scheduler schedule], %w[schedule]].freeze

        # Errno classes that mean "this path is not readable as a schedule" — swallowed so one bad path does
        # not cost the roots the other paths supply.
        IO_ERRORS = [Errno::ENOENT, Errno::EACCES, Errno::EISDIR].freeze

        def initialize(io_boundary:, schedule_paths:)
          @io_boundary = io_boundary
          @schedule_paths = schedule_paths
        end

        # @return [Array<String>] the class names named by a `class:` key in a schedule entry, sorted and
        #   unique. NOT yet intersected with the discovered workers — the caller does that.
        def worker_names
          names = Set.new
          @schedule_paths.each do |path|
            document = load_document(path)
            next unless document.is_a?(Hash)

            SCHEDULE_BLOCK_KEY_PATHS.each { |keys| collect_entries(dig_block(document, keys), names) }
          end
          names.to_a.sort
        end

        private

        def load_document(path)
          absolute = File.expand_path(path.to_s)
          # ADR-45 WD1b (#613) — the probe goes through the boundary so "there is no `config/sidekiq.yml`"
          # is a recorded dependency; `File.file?` here left the warm run serving the no-schedule answer
          # after the file appeared.
          return nil unless @io_boundary.file?(absolute)

          contents = read_safely(absolute)
          contents && parse_safely(contents)
        end

        def read_safely(path)
          @io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, *IO_ERRORS
          nil
        end

        # `safe_load` with no permitted classes beyond Symbol: a schedule file is data, and Rigor never loads
        # the Rails environment or the sidekiq runtime to read it. `aliases: true` because YAML anchors are
        # ordinary style in a hand-maintained schedule.
        def parse_safely(contents)
          YAML.safe_load(contents, aliases: true, permitted_classes: [Symbol])
        rescue Psych::Exception
          nil
        end

        # Walks one of {SCHEDULE_BLOCK_KEY_PATHS} into the document. String and Symbol keys are both tried because
        # `sidekiq.yml` is written with Symbol keys and `schedule.yml` with String ones.
        def dig_block(document, keys)
          keys.reduce(document) do |node, key|
            return nil unless node.is_a?(Hash)

            fetch_either(node, key)
          end
        end

        # A schedule block maps an arbitrary job NAME to an entry Hash. Only the entry's own `class:` is read
        # — no recursion into the value, so a nested option that happens to be called `class` cannot enter,
        # and neither can anything under `:queues:`, whose values are Strings and Arrays rather than entries.
        def collect_entries(block, names)
          return unless block.is_a?(Hash)

          block.each_value do |entry|
            next unless entry.is_a?(Hash)

            value = fetch_either(entry, CLASS_KEY)
            names << value if value.is_a?(String) && !value.empty?
          end
        end

        def fetch_either(hash, key)
          hash.fetch(key) { hash[key.to_sym] }
        end
      end
    end
  end
end
