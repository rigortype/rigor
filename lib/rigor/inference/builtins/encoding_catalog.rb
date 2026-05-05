# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Encoding` catalog. Singleton — load once, consult during
      # dispatch.
      #
      # Encoding instances are deep-frozen value objects: once
      # registered, their `name` / `dummy?` / `ascii_compatible?`
      # slots never change and the C bodies for the per-instance
      # methods are pure. The C-body classifier therefore lands
      # every instance method as `:leaf` correctly.
      #
      # The blocklist focuses on the *singleton* surface where the
      # hidden state is the process-wide encoding registry. Every
      # method classified `:leaf` on the singleton actually reads
      # (or, for the setters, writes) a global, so a hypothetical
      # `Constant<Encoding>`-class receiver MUST NOT fold them
      # against the analyzer process's registry — what UTF-8's
      # alias list is in the analyzer is not necessarily what it
      # is in the analysed program.
      ENCODING_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/encoding.yml",
          __dir__
        ),
        mutating_selectors: {
          "Encoding" => Set[
            # Defence-in-depth: mirrors range_catalog.rb /
            # complex_catalog.rb. Encoding does not currently
            # expose a public `initialize_copy` (Encoding objects
            # are deep-frozen and #dup is a no-op), but the
            # convention keeps the door closed against future
            # CRuby changes that would leak a copy-mutator.
            :initialize_copy,
            :hash,
            :eql?,
            # `Encoding.find(name)` walks the global encoding
            # registry. Pure with respect to its argument but
            # the registry itself can drift (load-order, locale,
            # process-wide `default_external=` calls), so a
            # constant-fold would lock in the analyzer's view.
            :find,
            # `Encoding.list` / `Encoding.aliases` /
            # `Encoding.name_list` enumerate the same global
            # registry. Same reasoning as `find` — the values
            # are not guaranteed to match the analysed program's
            # registry.
            :list,
            :aliases,
            :name_list,
            # Global-default mutators. `MethodCatalog#blocked?`
            # only auto-blocks `!`-suffixed selectors, so we MUST
            # list these explicitly: each writes the process-wide
            # default-encoding slot read by `default_external` /
            # `default_internal`.
            :default_external=,
            :default_internal=
          ]
        }
      )
    end
  end
end
