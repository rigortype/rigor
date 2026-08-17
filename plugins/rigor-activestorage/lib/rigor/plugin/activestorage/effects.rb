# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class Activestorage < Rigor::Plugin::Base
      # rigor-activestorage's effect contract (ADR-103 WD10; design note § 11.2; issue #387).
      #
      # ActiveStorage is the design note's argument for framework labels in miniature: the *transport* is
      # whatever `config/storage.yml` names — the local disk, S3, GCS — and is therefore statically
      # unknowable, while the *operation* is fixed. So every row carries bare `io` for the transport and
      # `rails.activestorage.read` / `.write` for the meaning, which is the half a policy can grip.
      #
      # Almost every write is also an `io.db.write`: an attachment is a row in `active_storage_attachments`
      # and a blob is a row in `active_storage_blobs`, so `user.avatar.attach(io)` really does touch the
      # database whether or not the bytes go to S3. A "no database writes on this path" envelope is right
      # to object, and would be wrong not to.
      module Effects
        ATTACHED_ONE = "ActiveStorage::Attached::One"
        ATTACHED_MANY = "ActiveStorage::Attached::Many"
        BLOB = "ActiveStorage::Blob"
        ATTACHMENT = "ActiveStorage::Attachment"

        READ = ["io", "rails.activestorage.read"].freeze
        WRITE = ["io", "rails.activestorage.write", "io.db.write"].freeze
        # `download` / `open` pull bytes out of the service and touch no row.
        PURE_READ = ["io", "rails.activestorage.read"].freeze

        ATTACH_TARGETS = [ATTACHED_ONE, ATTACHED_MANY].freeze

        module_function

        def attributions
          attach_rows + blob_rows
        end

        def attach_rows
          ATTACH_TARGETS.flat_map do |receiver|
            [
              row(receiver, :attach, WRITE,
                  "uploads the bytes to the configured service AND inserts the attachment + blob rows"),
              row(receiver, :purge, WRITE, "deletes the stored file and the attachment + blob rows"),
              row(receiver, :purge_later, WRITE,
                  "enqueues the purge; the attachment row is detached now, so the database write is here"),
              row(receiver, :detach, ["io.db.write"], "removes the attachment row and touches no service"),
              row(receiver, :download, PURE_READ, "pulls the bytes back out of the service"),
              row(receiver, :open, PURE_READ, "streams the bytes into a tempfile")
            ]
          end
        end

        def blob_rows
          [
            row(BLOB, :download, PURE_READ, "reads the object out of the storage service"),
            row(BLOB, :open, PURE_READ, "streams the object into a tempfile"),
            row(BLOB, :upload, WRITE, "writes the object to the service and records its checksum"),
            row(BLOB, :purge, WRITE, "deletes the object and its row"),
            row(BLOB, :purge_later, WRITE, "enqueues the object's deletion; the row goes now"),
            row(BLOB, :create_and_upload!, WRITE, "inserts the blob row and uploads in one call",
                singleton: true),
            row(BLOB, :url, READ, "signs a URL against the service, which for some services is a request"),
            row(ATTACHMENT, :purge, WRITE, "deletes the stored file and the attachment row"),
            row(ATTACHMENT, :download, PURE_READ, "reads the attached object out of the service")
          ]
        end

        def row(receiver, selector, labels, why, singleton: false)
          EffectAttribution.new(receiver: receiver, method: selector, labels: labels,
                                singleton: singleton, discharge: true,
                                why: "#{why}; the transport is bare `io` because `config/storage.yml` " \
                                     "decides it per environment and no static reading can")
        end
      end
    end
  end
end
