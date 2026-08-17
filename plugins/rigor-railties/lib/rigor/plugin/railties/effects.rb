# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class Railties < Rigor::Plugin::Base
      # rigor-railties' effect contract (ADR-103 WD10; design note § 11.2; issue #387).
      #
      # The rows for the `Rails.` namespace itself — the cache, the logger, the environment, the
      # configuration, the credentials. Every one of them is spelled as a **receiver path**, because that
      # is the only handle there is: `Rails.cache` returns whatever `config.cache_store` names, and
      # `Rails.logger` whatever the app assigned, so the receiver has no class a row could key on. The
      # path the programmer wrote is stable where the type is not.
      #
      # ## `Rails.env` is `global.read`, and that is not pedantry
      #
      # `Rails.env = "test"` is a real thing people do, and a memoisation keyed on `Rails.env` in a class
      # loaded before the environment is set is a real bug. So the label is honest — and then a project
      # writes `tolerated: [rails.config.read]` and stops seeing it, which is the mechanism working
      # correctly: the record stays true, the judgment gets quiet.
      #
      # ## The credentials read is a file read
      #
      # `Rails.application.credentials.secret_key_base` decrypts `config/credentials.yml.enc` on first
      # access. `io.fs.read` plus `global.read` (the decrypted bag is memoised process-wide) plus
      # `rails.credentials.read`, which is the one a "this layer touches no secrets" policy names.
      module Effects
        CACHE = "Rails.cache"
        LOGGER = "Rails.logger"
        ERROR = "Rails.error"
        RAILS = "Rails"

        CACHE_READ = ["io", "cache.read"].freeze
        CACHE_WRITE = ["io", "cache.write"].freeze
        TELEMETRY = %w[io telemetry].freeze
        CONFIG_READ = ["global.read", "rails.config.read"].freeze
        CREDENTIALS = ["io.fs.read", "global.read", "rails.credentials.read"].freeze
        STATIC_WRITE = ["global.write", "mutate.static"].freeze

        CACHE_READERS = %w[read read_multi exist? fetch fetch_multi].freeze
        CACHE_WRITERS = %w[write write_multi delete delete_matched delete_multi increment decrement
                           clear cleanup].freeze
        LOG_LEVELS = %w[debug info warn error fatal unknown add log tagged silence].freeze
        CONFIG_READERS = %w[env root configuration application logger cache version public_path
                            groups autoloaders].freeze

        # Where a project's own logger lives, in the classes Rails gives one to. Spelled as a self path so
        # a receiver-less `logger` inside a model or a controller is coloured and a `logger` method on some
        # unrelated project class is not.
        LOGGER_HOSTS = %w[ActiveRecord::Base ActionController::Base ActiveJob::Base ActionMailer::Base].freeze

        module_function

        def attributions
          cache_rows + logger_rows + error_rows + config_rows + credentials_rows + mutation_rows
        end

        def cache_rows
          CACHE_READERS.map do |selector|
            path_row(CACHE, selector, CACHE_READ,
                     "reads the configured cache store — memory, Redis or the filesystem, which is why " \
                     "the transport is bare `io`. `fetch`'s block is this method's own code and joins by " \
                     "containment, so a cache miss's cost shows up in the caller either way")
          end +
            CACHE_WRITERS.map do |selector|
              path_row(CACHE, selector, CACHE_WRITE, "writes the configured cache store")
            end
        end

        def logger_rows
          LOG_LEVELS.map do |selector|
            path_row(LOGGER, selector, TELEMETRY,
                     "writes to whatever the app assigned as the logger — a file, stdout, a log " \
                     "aggregator. `telemetry` is the label a project tolerates once and then stops " \
                     "thinking about, which is exactly what it is for")
          end +
            LOGGER_HOSTS.flat_map do |host|
              LOG_LEVELS.map do |selector|
                EffectAttribution.new(
                  receiver: "self.logger", method: selector, labels: TELEMETRY, within: host,
                  discharge: true,
                  why: "a receiver-less `logger` inside a Rails class is `Rails.logger`; `within:` is what " \
                       "keeps a `logger` method on an unrelated project class out of this row"
                )
              end
            end
        end

        def error_rows
          %w[report handle record].map do |selector|
            path_row(ERROR, selector, TELEMETRY,
                     "reports to the error subscribers — Sentry, Honeybadger, a log line; the destination " \
                     "is registered at boot and is not statically knowable")
          end
        end

        def config_rows
          CONFIG_READERS.map do |selector|
            EffectAttribution.new(
              receiver: RAILS, method: selector, labels: CONFIG_READ, singleton: true, discharge: true,
              why: "reads mutable process state. `Rails.env = \"test\"` is a real thing people do, and a " \
                   "value memoised from it before boot finishes is a real bug — so the row is honest and " \
                   "`tolerated: [rails.config.read]` is how a project makes it quiet"
            )
          end + config_path_rows
        end

        def config_path_rows
          %w[Rails.configuration Rails.application.config Rails.application.config.x].flat_map do |path|
            %w[[] method_missing].map do |selector|
              EffectAttribution.new(receiver: path, method: selector, labels: CONFIG_READ, discharge: true,
                                    why: "reads the application configuration object, which is mutable " \
                                         "process state")
            end
          end
        end

        def credentials_rows
          %w[Rails.application.credentials Rails.application.secrets].flat_map do |path|
            %w[[] dig fetch config].map do |selector|
              EffectAttribution.new(
                receiver: path, method: selector, labels: CREDENTIALS, discharge: true,
                why: "decrypts `config/credentials.yml.enc` on first access and memoises it process-wide; " \
                     "`rails.credentials.read` is what a 'this layer touches no secrets' policy names"
              )
            end
          end
        end

        def mutation_rows
          [
            EffectAttribution.new(
              receiver: "Rails.application", method: :reload_routes!, labels: STATIC_WRITE, discharge: true,
              why: "rebuilds the route set on the application object — process-global mutation"
            ),
            EffectAttribution.new(
              receiver: "Rails.autoloaders.main", method: :reload, labels: STATIC_WRITE, discharge: true,
              why: "unloads and reloads every autoloaded constant"
            ),
            EffectAttribution.new(
              receiver: "ActiveRecord::Base", method: :establish_connection, labels: STATIC_WRITE,
              singleton: true, discharge: true,
              why: "replaces the connection pool for the class and everything below it"
            )
          ]
        end

        def path_row(path, selector, labels, why)
          EffectAttribution.new(receiver: path, method: selector, labels: labels, discharge: true, why: why)
        end

        # The `rails` preset: everything a request or a queue can enter the application through.
        # Expressed as globs rather than as a class-ancestry filter because `reach:` is resolved from the
        # snapshot's own method table, which carries a defining path per key and no ancestry — and in a
        # Rails app the layout IS the ancestry, which is why the convention exists.
        def entry_points
          [
            EffectEntryPoints.new(
              name: "rails",
              globs: ["app/controllers/**/*.rb", "app/jobs/**/*.rb", "app/mailers/**/*.rb",
                      "app/channels/**/*.rb"],
              why: "every way the outside world enters a Rails application: controller actions, job " \
                   "`perform`, mailer actions, channel callbacks"
            )
          ]
        end
      end
    end
  end
end
