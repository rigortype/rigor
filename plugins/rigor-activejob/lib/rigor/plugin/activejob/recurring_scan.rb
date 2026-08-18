# frozen_string_literal: true

require "yaml"

module Rigor
  module Plugin
    class Activejob < Rigor::Plugin::Base
      # ADR-102 WD3 / #369 — which jobs does this project run on a schedule it names them in by STRING?
      #
      # `MyJob.perform_later(...)` writes the job's name as an ordinary constant, so the reachability scan
      # already records that edge and a root would add nothing. Solid Queue's recurring tasks are the
      # opposite case, and they are why this file exists: a recurring job is named only as
      # `class: "SendReminderJob"` in `config/recurring.yml`, so a repository running it every three minutes
      # may contain no `perform_later` for it anywhere. The constant scan sees nothing and `rigor unused`
      # reports a production job as dead code — measured on a real Rails 8 application, where one miss
      # cascaded into a second row because the only caller of a helper class was the job itself.
      #
      # Solid Queue is the default Active Job backend from Rails 8, so this is a mainstream layout rather
      # than a niche one. This is also the ONLY root source this plugin has: #350 declined to publish the
      # discovered job set, because "a file exists under `app/jobs`" is not evidence that anything enqueues
      # it, and an over-claiming root source silently hides real dead code (ADR-102 § Consequences).
      #
      # **Two layouts, one key.** Rails 8 keys `recurring.yml` by environment at the top level
      # (`production:` → task name → entry), unlike `sidekiq-cron`'s flat document. Both depths are read
      # rather than guessed at, and reading both is safe because neither layout yields anything under the
      # other's reading: an environment block's values are entry Hashes whose own `class:` is absent, and a
      # flat entry's values are Strings rather than Hashes. Every environment is read — a job scheduled only
      # in `staging:` is still live code, and picking `production:` would report it dead.
      #
      # **A `command:` entry supplies nothing.** Solid Queue also accepts inline Ruby
      # (`command: "SomeModel.cleanup"`), which names no class the way `class:` does. Parsing a constant out
      # of an arbitrary Ruby snippet would manufacture roots from a string, so `class:` is the only key read.
      #
      # Names are not trusted either: the caller intersects them with the jobs {JobDiscoverer} actually
      # found, so a typo or an out-of-tree class costs coverage rather than manufacturing a root, and the
      # report's `matched no declaration` counter stays meaningful.
      #
      # Fail-soft throughout, because this reads user-authored config Rigor does not own: an absent file, an
      # unreadable one, a YAML syntax error, or a document that is not a Hash contributes nothing rather than
      # raising. Never boots Rails and never loads Solid Queue.
      class RecurringScan
        # The key naming the job class. `command:` is deliberately not read; see the class comment.
        CLASS_KEY = "class"

        # Errno classes that mean "this path is not readable as a schedule" — swallowed so one bad path does
        # not cost the roots the other paths supply.
        IO_ERRORS = [Errno::ENOENT, Errno::EACCES, Errno::EISDIR].freeze

        def initialize(io_boundary:, recurring_paths:)
          @io_boundary = io_boundary
          @recurring_paths = recurring_paths
        end

        # @return [Array<String>] the class names named by a `class:` key in a recurring-task entry, sorted
        #   and unique. NOT yet intersected with the discovered jobs — the caller does that.
        def job_names
          names = Set.new
          @recurring_paths.each do |path|
            document = load_document(path)
            next unless document.is_a?(Hash)

            collect_tasks(document, names)
            document.each_value { |block| collect_tasks(block, names) }
          end
          names.to_a.sort
        end

        private

        def load_document(path)
          absolute = File.expand_path(path.to_s)
          return nil unless File.file?(absolute)

          contents = read_safely(absolute)
          contents && parse_safely(contents)
        end

        def read_safely(path)
          @io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, *IO_ERRORS
          nil
        end

        # `safe_load` with no permitted classes beyond Symbol: a schedule file is data, and Rigor never loads
        # the Rails environment or the Solid Queue runtime to read it. `aliases: true` because YAML anchors
        # are ordinary style in a hand-maintained schedule that repeats a task across environments.
        def parse_safely(contents)
          YAML.safe_load(contents, aliases: true, permitted_classes: [Symbol])
        rescue Psych::Exception
          nil
        end

        # A task block maps an arbitrary task NAME to an entry Hash. Only the entry's own `class:` is read —
        # no recursion into the value, so an `args:` payload that happens to carry a `class` key cannot
        # enter.
        def collect_tasks(block, names)
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
