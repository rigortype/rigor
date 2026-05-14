# frozen_string_literal: true

module Rigor
  module Plugin
    class Activestorage < Rigor::Plugin::Base
      # Maps a discovered class name to the list of attachment
      # rows declared on it. Marshal-clean so the cache producer
      # round-trips it through the standard pair.
      #
      # Each row is `{ name:, kind: }`:
      #
      # - `name` — String, the attachment method name as the
      #            user invokes it (`"avatar"`).
      # - `kind` — `:singular` (`has_one_attached`) or
      #            `:collection` (`has_many_attached`).
      class AttachmentIndex
        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          freeze
        end

        def attachments_for(class_name)
          entries[class_name.to_s]
        end

        def class_names = entries.keys

        def empty? = entries.empty?

        def self.build(rows:)
          entries = rows.each_with_object({}) do |row, acc|
            class_name = row.fetch(:class_name)
            attachments = Array(row[:attachments]).map(&:freeze).freeze
            acc[class_name] = attachments
          end
          new(entries.freeze)
        end
      end
    end
  end
end
