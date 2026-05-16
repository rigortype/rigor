# frozen_string_literal: true

module Rigor
  module LanguageServer
    # LSP DocumentUri ↔ filesystem path conversions. v1 supports
    # only `file://` URIs; other schemes (e.g. `untitled:`) return
    # nil from `#to_path` so the caller can short-circuit.
    #
    # Windows drive-letter handling: `file:///C:/path` → `C:/path`.
    # The leading slash after the scheme is dropped on Windows; on
    # POSIX it stays. v1 ships POSIX behaviour; Windows specifics
    # land when Windows CI is wired (see design doc § "Open
    # questions").
    module Uri
      module_function

      FILE_SCHEME = "file://"
      private_constant :FILE_SCHEME

      # @return [String, nil] absolute filesystem path for a
      #   `file://` URI, or nil for unsupported schemes.
      def to_path(uri)
        return nil unless uri.is_a?(String) && uri.start_with?(FILE_SCHEME)

        # Percent-decode at the BYTE level so multi-byte UTF-8
        # escapes (`%E6%97%A5` → `日`) reassemble correctly. Each
        # `%xx` decodes to one raw byte; the result is a byte string
        # we re-interpret as UTF-8. `delete_prefix` always returns
        # a String (vs `byteslice` whose RBS return is `String?`).
        uri.delete_prefix(FILE_SCHEME).b
           .gsub(/%([0-9A-Fa-f]{2})/) { ::Regexp.last_match(1).hex.chr }
           .force_encoding(Encoding::UTF_8)
      end

      def from_path(path)
        "#{FILE_SCHEME}#{path}"
      end
    end
  end
end
