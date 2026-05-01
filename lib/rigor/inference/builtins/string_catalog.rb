# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `String` and `Symbol` catalog. Singleton — load once,
      # consult during dispatch.
      #
      # The blocklist below is the curated set of catalog `:leaf`
      # entries the C-body classifier mis-attributes (the body of
      # `rb_str_replace` calls `str_modifiable` / `str_discard`
      # which the regex-based classifier does not recognise as
      # mutation primitives). Adding to the blocklist is the
      # corrective surface for false positives until the
      # classifier learns the helper functions.
      STRING_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/string.yml",
          __dir__
        ),
        mutating_selectors: {
          "String" => Set[
            :replace, :initialize, :initialize_copy, :clear, :<<, :concat, :insert,
            :prepend, :force_encoding, :encode, :scrub, :unicode_normalize, :"[]=",
            :upto, :each_byte, :each_char, :each_codepoint,
            :each_grapheme_cluster, :each_line, :bytesplice
          ],
          "Symbol" => Set[
            # Symbol is immutable in Ruby; the classifier mis-flags
            # `inspect` because `rb_sym_inspect` builds a temporary
            # mutable buffer. Allow it.
          ]
        }
      )
    end
  end
end
