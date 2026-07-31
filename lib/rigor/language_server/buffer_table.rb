# frozen_string_literal: true

require_relative "incremental_sync"

module Rigor
  module LanguageServer
    # Per-session virtual file table. The LSP server maintains the canonical view of every open buffer here;
    # analysis (slice 4+) reads from this table instead of disk so in-flight edits are reflected immediately.
    #
    # Keyed by `DocumentUri` (LSP `file://...` URIs). Sync is INCREMENTAL (LSP
    # `TextDocumentSyncKind::Incremental = 2`): a `didChange` carries range edits which {#apply_changes} splices
    # into the held text through {IncrementalSync}. The full-text form ({#change}, and a `contentChanges` entry
    # with no `range`) stays supported — it is still legal under incremental sync and is what `didOpen` and a
    # client-side resync send.
    class BufferTable
      # @!attribute uri      [String]  the LSP DocumentUri (e.g. `file:///abs/path/lib/foo.rb`).
      # @!attribute bytes    [String]  the current full text of the buffer.
      # @!attribute version  [Integer] the monotonically increasing LSP version number.
      Entry = Data.define(:uri, :bytes, :version)

      def initialize
        @entries = {}
        @desynchronized = {}
        @dirty = {}
      end

      # Records a `textDocument/didOpen` event. Replaces any existing entry (LSP clients may re-open a
      # previously closed URI; the new version is authoritative) and clears any desynchronised mark — the
      # payload carries the client's full text, so the two views agree again.
      def open(uri:, bytes:, version:)
        @desynchronized.delete(uri)
        @dirty.delete(uri)
        @entries[uri] = Entry.new(uri: uri, bytes: bytes, version: version)
      end

      # Records a full-text `textDocument/didChange`. The full new buffer text replaces the entry. If the
      # client sends a `didChange` for a URI that was never opened (spec violation), the entry is still
      # created — defensive.
      def change(uri:, bytes:, version:)
        @desynchronized.delete(uri)
        @dirty[uri] = true
        @entries[uri] = Entry.new(uri: uri, bytes: bytes, version: version)
      end

      # Applies a `textDocument/didChange` payload under INCREMENTAL sync. Each entry of `changes` is applied
      # in order against the result of the previous one, per the LSP contract.
      #
      # On success the entry is replaced with the spliced text at the new version. On failure — a malformed
      # change, or a range edit for a URI with no held buffer — the held text is left EXACTLY as it was and the
      # URI is marked desynchronised: the server's view and the editor's view have diverged, and every position
      # computed from the stale text would be wrong. Consumers check {#desynchronized?} and decline to answer
      # rather than answering wrongly; the mark clears on the next `didOpen` or full-text change.
      #
      # @return [Boolean] true when the changes were applied.
      def apply_changes(uri:, changes:, version:)
        text = IncrementalSync.apply_all(@entries[uri]&.bytes, changes)
        @desynchronized.delete(uri)
        @dirty[uri] = true
        @entries[uri] = Entry.new(uri: uri, bytes: text, version: version)
        true
      rescue IncrementalSync::UnappliableChange => e
        @desynchronized[uri] = e.message
        false
      end

      # @return [Boolean] true when the last `didChange` for `uri` could not be applied, so the held text no
      #   longer matches the editor's.
      def desynchronized?(uri)
        @desynchronized.key?(uri)
      end

      # @return [String, nil] why `uri` is desynchronised, for the log line; nil when it is in sync.
      def desynchronization_reason(uri)
        @desynchronized[uri]
      end

      # Records a `textDocument/didClose` event. The entry is removed. Subsequent reads via `#[]` return nil.
      def close(uri:)
        @desynchronized.delete(uri)
        @dirty.delete(uri)
        @entries.delete(uri)
      end

      # Records a `textDocument/didSave`. The client has written the buffer, so the held text and the file on
      # disk agree again and the URI stops being dirty.
      #
      # Dirtiness is the PROTOCOL's notion — "the client told us it changed and has not told us it saved" —
      # not a byte comparison against disk. A comparison would look stricter and be weaker: it races with the
      # editor's own write, and the server's truth is what the client notified.
      def save(uri:)
        @dirty.delete(uri)
      end

      # @return [Boolean] true when `uri` has unsaved changes. A buffer that is dirty may only be published
      #   from an analysis that bound ITS bytes — see the publish-set invariant in
      #   `docs/design/20260517-language-server.md`.
      def dirty?(uri)
        @dirty.key?(uri)
      end

      def [](uri)
        @entries[uri]
      end

      def open?(uri)
        @entries.key?(uri)
      end

      def size
        @entries.size
      end

      def uris
        @entries.keys
      end
    end
  end
end
