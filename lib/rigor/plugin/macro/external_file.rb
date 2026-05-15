# frozen_string_literal: true

module Rigor
  module Plugin
    module Macro
      # ADR-16 Tier D declaration: "files matching `glob` are
      # analysed as if their body were pasted at a call site whose
      # `self` is an instance of `receiver_type` (and whose `@ivar`
      # facts come from `bound_ivars`)."
      #
      # Worked motivating cases (per the per-library survey):
      #
      # - Redmine's `WebhookPayload#instance_eval(File.read(path), path, 1)`
      #   at `app/models/webhook_payload.rb:71`. The payload templates
      #   under `config/webhooks/*.rb` run with `self` typed as
      #   `Redmine::WebhookPayload` and ivars like `@event` / `@issue`
      #   / `@user` pre-bound by the caller.
      # - tDiary Core's plugin loader pattern — `misc/plugin/*.rb`
      #   files loaded under `instance_eval` with the tDiary plugin
      #   instance as `self`.
      #
      # ## Authoring shape
      #
      #     manifest(
      #       id: "redmine-webhook-payloads",
      #       version: "0.1.0",
      #       external_files: [
      #         Rigor::Plugin::Macro::ExternalFile.new(
      #           glob: "config/webhooks/*.rb",
      #           receiver_type: "Redmine::WebhookPayload",
      #           bound_ivars: {
      #             "@event" => "Symbol",
      #             "@issue" => "Issue?",
      #             "@user"  => "User"
      #           }
      #         )
      #       ]
      #     )
      #
      # ## Fields
      #
      # - `glob` — non-empty String pattern. Interpreted relative
      #   to the project root (the directory containing `.rigor.yml`)
      #   at scan time. Slice 5a accepts any non-empty glob
      #   pattern syntactically; the engine integration (slice 5b)
      #   pins the resolution rule.
      # - `receiver_type` — non-empty String. The class name `self`
      #   inside the loaded file binds to. Engine integration (slice
      #   5b) narrows the file-entry scope's `self_type` to
      #   `Nominal[receiver_type]`.
      # - `bound_ivars` — Hash<String, String>. Each key MUST start
      #   with `@`; each value is a non-empty type-name String. The
      #   engine pre-binds these as ivar facts in the file-entry
      #   scope (slice 5b).
      #
      # ## Slice 5a scope
      #
      # **This file ships the value class + manifest hook ONLY.**
      # The engine integration that (a) adds matched files to the
      # analysis set, (b) narrows the file-entry `self_type`, and
      # (c) pre-binds `bound_ivars` as ivar facts is **queued for
      # slice 5b**, gated on demonstrated demand. The survey
      # identifies only Redmine + tDiary as concrete consumers;
      # premature engine work is deferred until those cases (or
      # equivalents) materialise as committed plugin targets.
      #
      # With only this slice landed, plugin authors CAN declare a
      # Tier D manifest entry today — the declaration round-trips
      # through `Manifest#to_h` (cache-key stable) and is exposed
      # on `Manifest#external_files` — but the substrate does not
      # yet act on it. The contract is forward-compatible: when
      # slice 5b lands, the engine reads the same declarations and
      # plugin gems do not need to change.
      class ExternalFile
        attr_reader :glob, :receiver_type, :bound_ivars

        def initialize(glob:, receiver_type:, bound_ivars: {})
          validate_glob!(glob)
          validate_receiver_type!(receiver_type)
          validate_bound_ivars!(bound_ivars)

          @glob = glob.dup.freeze
          @receiver_type = receiver_type.dup.freeze
          @bound_ivars = bound_ivars.to_h { |k, v| [k.dup.freeze, v.dup.freeze] }.freeze
          freeze
        end

        def to_h
          {
            "glob" => glob,
            "receiver_type" => receiver_type,
            "bound_ivars" => bound_ivars
          }
        end

        def ==(other)
          other.is_a?(ExternalFile) && to_h == other.to_h
        end
        alias eql? ==

        def hash
          to_h.hash
        end

        private

        def validate_glob!(value)
          return if value.is_a?(String) && !value.empty?

          raise ArgumentError,
                "Plugin::Macro::ExternalFile#glob must be a non-empty String, got #{value.inspect}"
        end

        def validate_receiver_type!(value)
          return if value.is_a?(String) && !value.empty?

          raise ArgumentError,
                "Plugin::Macro::ExternalFile#receiver_type must be a non-empty String, got #{value.inspect}"
        end

        def validate_bound_ivars!(value)
          unless value.is_a?(Hash)
            raise ArgumentError,
                  "Plugin::Macro::ExternalFile#bound_ivars must be a Hash, got #{value.inspect}"
          end

          value.each do |k, v|
            unless k.is_a?(String) && k.start_with?("@") && k.length > 1
              raise ArgumentError,
                    "Plugin::Macro::ExternalFile#bound_ivars key must be a String starting with `@`, " \
                    "got #{k.inspect}"
            end
            next if v.is_a?(String) && !v.empty?

            raise ArgumentError,
                  "Plugin::Macro::ExternalFile#bound_ivars value must be a non-empty String, " \
                  "got #{v.inspect}"
          end
        end
      end
    end
  end
end
