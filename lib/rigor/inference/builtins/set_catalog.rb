# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Set` catalog. Singleton — load once, consult during dispatch.
      #
      # Set was rewritten in C and folded into CRuby for Ruby 3.2+;
      # the reference branch (`ruby_4_0`) ships the implementation in
      # `references/ruby/set.c` with `Init_Set` registering every
      # method directly. There is no `set.rb` prelude — the trailing
      # `rb_provide("set.rb")` makes `require "set"` a no-op against
      # the built-in.
      #
      # The blocklist below catches the catalog `:leaf` entries the
      # C-body classifier mis-attributes. Set's iteration helpers
      # (`set_iter`, `RETURN_SIZED_ENUMERATOR`) and its identity-
      # mode and reset paths drive into helpers the regex classifier
      # does not yet recognise as block-yielding or mutating.
      SET_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/set.yml",
          __dir__
        ),
        mutating_selectors: {
          "Set" => Set[
            # Indirect mutators classified `:leaf` because the C
            # classifier did not follow the helper functions:
            #
            # - `initialize_copy` calls `set_copy` to overwrite the
            #   receiver's table.
            # - `compare_by_identity` swaps the internal hash type
            #   via `set_reset_table_with_type`.
            # - `reset` rebuilds the internal table to dedup after
            #   element mutation.
            :initialize_copy, :compare_by_identity, :reset,
            # Block-dependent methods classified `:leaf` because the
            # C body uses `set_iter` / `RETURN_SIZED_ENUMERATOR`
            # rather than calling `rb_yield` directly:
            :each, :classify, :divide,
            # `disjoint?` delegates into `set_i_intersect`, which
            # for non-Set enumerables uses `rb_funcall(other,
            # :any?, ...)` — that is user-redefinable dispatch the
            # classifier missed because the call site is in a
            # sibling function.
            :disjoint?
          ]
        }
      )
    end
  end
end
