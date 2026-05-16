# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-17 § "Inference contract" — project-wide patched-method
    # registry populated by the pre-eval pre-pass (slice 2) from
    # the user's `.rigor.yml` `pre_eval:` list.
    #
    # Each entry records one `def` declaration the pre-pass
    # observed inside a class / module body. The dispatcher's
    # `try_project_patched_method` tier consults this registry
    # between the plugin tier and the dependency-source tier so
    # project-side `lib/core_ext/string_extensions.rb` patches
    # are visible to cross-file dispatch.
    #
    # Slice 2 ships the registry at the **floor**: the dispatcher
    # answers `Type::Combinator.untyped` (Dynamic[Top]) on a hit;
    # return-type inference for patched methods stays deferred
    # (a separate slice when concrete demand surfaces — most
    # real-world `core_ext` patches return shapes the analyzer
    # could heuristically extract via the same machinery the
    # ADR-10 walker uses, but slice 2 keeps the surface narrow).
    class ProjectPatchedMethods
      # Frozen value-object recording one `def` observed by the
      # pre-pass. `class_name` is the qualified prefix
      # (`"String"`, `"Foo::Bar"`); `method_name` is the
      # declared name; `kind` is `:instance` or `:singleton`;
      # `source_path` / `source_line` carry attribution for
      # diagnostics.
      Entry = Data.define(:class_name, :method_name, :kind, :source_path, :source_line)

      attr_reader :by_key

      # @param entries [Array<Entry>] flat list of declarations
      #   observed during the pre-pass. First-write-wins on
      #   `(class_name, method_name, kind)` duplicates so the
      #   `pre-eval.duplicate-declaration` diagnostic emission
      #   stays decoupled from registry behaviour.
      def initialize(entries: [])
        @by_key = entries.each_with_object({}) do |entry, acc|
          key = [entry.class_name, entry.method_name, entry.kind]
          acc[key] ||= entry
        end.freeze
        freeze
      end

      # @return [Entry, nil] the recorded entry for the given
      #   `(class_name, method_name, kind)` triple, or `nil`
      #   when no pre-eval file declared it.
      def lookup(class_name:, method_name:, kind:)
        @by_key[[class_name, method_name, kind]]
      end

      def empty?
        @by_key.empty?
      end

      EMPTY = new.freeze
    end
  end
end
