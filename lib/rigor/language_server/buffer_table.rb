# frozen_string_literal: true

module Rigor
  module LanguageServer
    # Per-session virtual file table. The LSP server maintains the
    # canonical view of every open buffer here; analysis (slice 4+)
    # reads from this table instead of disk so in-flight edits are
    # reflected immediately.
    #
    # Keyed by `DocumentUri` (LSP `file://...` URIs). v1 ships
    # FULL text sync (LSP `TextDocumentSyncKind::Full = 1`) so each
    # `didChange` carries the entire buffer text — there's no
    # incremental edit application yet. Incremental sync is slice
    # 10 (deferred per the design doc).
    class BufferTable
      # @!attribute uri      [String]  the LSP DocumentUri (e.g. `file:///abs/path/lib/foo.rb`).
      # @!attribute bytes    [String]  the current full text of the buffer.
      # @!attribute version  [Integer] the monotonically increasing LSP version number.
      Entry = Data.define(:uri, :bytes, :version)

      def initialize
        @entries = {}
      end

      # Records a `textDocument/didOpen` event. Replaces any
      # existing entry (LSP clients may re-open a previously closed
      # URI; the new version is authoritative).
      def open(uri:, bytes:, version:)
        @entries[uri] = Entry.new(uri: uri, bytes: bytes, version: version)
      end

      # Records a `textDocument/didChange` event under FULL sync.
      # The full new buffer text replaces the entry. If the client
      # sends a `didChange` for a URI that was never opened (spec
      # violation), the entry is still created — defensive.
      def change(uri:, bytes:, version:)
        @entries[uri] = Entry.new(uri: uri, bytes: bytes, version: version)
      end

      # Records a `textDocument/didClose` event. The entry is
      # removed. Subsequent reads via `#[]` return nil.
      def close(uri:)
        @entries.delete(uri)
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
