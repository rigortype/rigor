# frozen_string_literal: true

module Rigor
  module Source
    # The Symbol a name's text denotes, or `nil` when no Symbol can hold its bytes.
    #
    # `"\xff".to_sym` raises EncodingError, and a String literal may carry any bytes (a Symbol literal with invalid
    # bytes is a syntax error, so no analysed file has one). Every reader of a literal name goes through here, so such
    # a name reads as `nil` — the answer a computed name already gets — instead of aborting the file's analysis (#1821).
    # `valid_encoding?` is the test, not `ascii_only?`: a name that is valid in its own encoding (a binary or Shift_JIS
    # source) is a real Symbol.
    module SymbolName
      module_function

      def of(text)
        text.to_sym if text&.valid_encoding?
      end
    end
  end
end
