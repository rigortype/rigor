# frozen_string_literal: true

module Rigor
  module Plugin
    class Actioncable < Rigor::Plugin::Base
      # Frozen catalogue of discovered ActionCable channel
      # classes keyed by qualified class name. Each entry
      # holds:
      #
      # - `action_methods` — the set of public instance
      #   methods that aren't ActionCable framework hooks
      #   (`subscribed` / `unsubscribed`). These are the
      #   methods clients invoke via
      #   `subscription.perform("action_name", data)`.
      # - `stream_names` — the set of literal-string stream
      #   names registered via `stream_from "name"` calls
      #   inside the channel body. Dynamic registrations
      #   (`stream_from interpolated_string`) are recorded
      #   separately as `dynamic_streams: true` so the
      #   analyzer can suppress unknown-stream warnings on
      #   any channel that has at least one dynamic
      #   registration.
      class ChannelIndex
        Entry = Data.define(:class_name, :file_path, :action_methods, :stream_names, :dynamic_streams) do
          def includes_action?(name)
            action_methods.include?(name.to_sym)
          end

          def known_actions
            action_methods.to_a.sort
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

        # All literal stream names registered across every
        # discovered channel.
        def all_stream_names
          @entries.flat_map { |e| e.stream_names.to_a }.to_set
        end

        # True when at least one discovered channel uses a
        # dynamic stream registration. The analyzer treats
        # this as "we can't be sure any literal name is
        # missing" and downgrades unknown-stream from
        # `:warning` to `:info` (or drops it entirely;
        # current behaviour: skip warnings).
        def any_dynamic_streams?
          @entries.any?(&:dynamic_streams)
        end
      end
    end
  end
end
