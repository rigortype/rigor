# frozen_string_literal: true

module Rigor
  module Plugin
    class Activestorage < Rigor::Plugin::Base
      # Maps a discovered class name to the list of attachment rows declared on it. Marshal-clean so the
      # cache producer round-trips it through the standard pair.
      #
      # Each row is `{ name:, kind: }`:
      #
      # - `name` — String, the attachment method name as the user invokes it (`"avatar"`).
      # - `kind` — `:singular` (`has_one_attached`) or `:collection` (`has_many_attached`).
      class AttachmentIndex
        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          freeze
        end

        # Entries are keyed by the de-rooted constant path (`"User"`, `"Admin::User"` — never `"::User"`;
        # see {AttachmentDiscoverer}), while a QUERY may legitimately arrive rooted: a `Nominal` receiver
        # for `::User` renders its class name as `"::User"`. The root marker is dropped here, once, so no
        # caller needs an `attachments_for(name) || attachments_for("::#{name}")` retry (#621).
        def attachments_for(class_name)
          entries[class_name.to_s.delete_prefix("::")]
        end

        def class_names = entries.keys

        def empty? = entries.empty?

        # Rows that name the SAME class are UNIONed, not replaced. A model is routinely declared more than
        # once — `app/models/user.rb` holds the real class and a concern or an engine's file reopens it —
        # and a reopen ADDS attachments rather than replacing the class, so keeping only the last row in the
        # glob dropped the earlier declaration's `has_one_attached` and left `user.avatar` untyped. A
        # redeclared attachment NAME resolves to the later row, as it does at load time.
        def self.build(rows:)
          entries = rows.each_with_object({}) do |row, acc|
            class_name = row.fetch(:class_name)
            by_name = acc[class_name] || {}
            Array(row[:attachments]).each { |attachment| by_name[attachment[:name]] = attachment.freeze }
            acc[class_name] = by_name
          end
          new(entries.transform_values { |by_name| by_name.values.freeze }.freeze)
        end
      end
    end
  end
end
