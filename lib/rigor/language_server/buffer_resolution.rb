# frozen_string_literal: true

require_relative "uri"

module Rigor
  module LanguageServer
    # Shared buffer lookup for the LSP providers.
    #
    # Every provider's `provide` opens with the same two steps: translate the document URI to an on-disk path,
    # then fetch the open buffer entry from the buffer table — returning nil to the editor when either is
    # missing. The parse step that follows differs per provider (strict vs error-tolerant, whole-buffer vs
    # cursor-recovery), so only this resolution is shared here.
    module BufferResolution
      private

      # Resolves `[path, entry]` for the document `uri`, or nil when the uri has no file path or no open
      # buffer. A caller that destructures `path, entry = buffer_for(uri)` can guard on `entry.nil?` to cover
      # both misses (a nil return leaves both locals nil).
      def buffer_for(uri)
        path = Uri.to_path(uri)
        return nil if path.nil?

        entry = @buffer_table[uri]
        return nil if entry.nil?

        [path, entry]
      end
    end
  end
end
