# frozen_string_literal: true

require_relative "global_write_census"

module Rigor
  module Inference
    # ADR-17 § "Inference contract" — project-wide patched-method registry populated by the pre-eval
    # pre-pass (slice 2) from the user's `.rigor.yml` `pre_eval:` list.
    #
    # Each entry records one `def`, `alias` or `alias_method` declaration the pre-pass observed inside a class /
    # module body. The dispatcher's `try_project_patched_method` tier consults this registry between the plugin
    # tier and the dependency-source tier so project-side `lib/core_ext/string_extensions.rb` patches are visible
    # to cross-file dispatch.
    #
    # The dispatcher answers `Dynamic[T]` (with a heuristic static facet) when `Entry#return_type` is
    # non-nil, or `Dynamic[Top]` when the heuristic declined (`nil`). See {Entry} for the per-field
    # contract.
    class ProjectPatchedMethods
      # Frozen value-object recording one `def` observed by the pre-pass. `class_name` is the qualified
      # prefix (`"String"`, `"Foo::Bar"`); `method_name` is the declared name; `kind` is `:instance` or
      # `:singleton`; `source_path` / `source_line` carry attribution for diagnostics; `return_type` is
      # the {Analysis::DependencySourceInference::ReturnTypeHeuristic}-extracted static facet (a
      # `Rigor::Type::*`) or `nil` when the heuristic declined. The dispatcher wraps a non-nil
      # `return_type` in `Dynamic[T]`; a `nil` `return_type` falls back to `Dynamic[top]`.
      #
      # Issue #1702 — an `alias new old` / `alias_method :new, :old` in a patch is recorded too. When a `def` or
      # alias earlier in the `pre_eval:` files binds `old`, the alias's entry copies that entry's `return_type` (and
      # its `alias_of`); otherwise `alias_of` names `old`, a method the class had before the patch, and the
      # dispatcher answers the alias with what that method answers. `alias_of` is nil for a `def`.
      Entry = Data.define(:class_name, :method_name, :kind, :source_path, :source_line, :return_type, :alias_of) do
        def initialize(class_name:, method_name:, kind:, source_path:, source_line:, return_type: nil, alias_of: nil)
          super
        end
      end

      attr_reader :by_key, :write_census

      # @param entries — flat list of declarations observed during the pre-pass.
      #   Last-write-wins on `(class_name, method_name, kind)` duplicates, as at runtime (ADR-17); the
      #   `pre-eval.duplicate-declaration` diagnostic emission stays decoupled from registry behaviour.
      # @param write_census — issue #1367: the `pre_eval:` files' {GlobalWriteCensus}, which the `global.*` write
      #   rules join with the project's, since a patch file is loaded ahead of the code it patches.
      def initialize(entries: [], write_census: GlobalWriteCensus::EMPTY)
        @by_key = entries.each_with_object({}) do |entry, acc|
          key = [entry.class_name, entry.method_name, entry.kind]
          acc[key] = entry
        end.freeze
        @write_census = write_census.frozen? ? write_census : write_census.dup.freeze
        freeze
      end

      # @return the recorded entry for the given `(class_name, method_name, kind)` triple,
      #   or `nil` when no pre-eval file declared it.
      def lookup(class_name:, method_name:, kind:)
        @by_key[[class_name, method_name, kind]]
      end

      # Issue #1708 — the entry a `kind` receiver of `class_name` reaches through its ancestors, searched in Ruby's
      # order: a patch on `Object`, `Kernel`, `Numeric`, `Comparable` or `Enumerable` answers an `Integer`, `Array`
      # or `String` receiver, and a patch on a nearer ancestor wins over one on a farther. A class object's chain
      # is its singleton classes, then `Class`, `Module`, `Object`, `Kernel` and `BasicObject`, so `def zz` in
      # `class Object` answers `Integer.zz` too. The ancestors are the class's RBS ones; a class RBS does not
      # declare is searched as itself only, as {#lookup} searches it.
      #
      # It answers only which patch the chain holds. A method a nearer ancestor's RBS declares wins over the patch
      # in Ruby, so the callers ask once that RBS has come back without the method. A method the project's own
      # source defines on the way wins too: `source_defines` is called with each `owner, side` BEFORE that owner's
      # patch is read, and when it answers true the walk stops with no entry, leaving the call to what types that
      # method. That includes an owner holding both a patch and a source `def` (a `lib/` reopen loaded after the
      # patch, or a module the project prepends to it), unlike {#lookup}, which answers the patch.
      # @return the entry, or `nil` when no ancestor's patch declares the method ahead of a source `def`.
      def lookup_through_ancestors(class_name:, method_name:, kind:, rbs_loader:, source_defines: nil)
        return nil if empty?

        ancestor_keys(class_name.to_s, kind, rbs_loader).each do |owner, side|
          return nil if source_defines&.call(owner, side)

          entry = @by_key[[owner, method_name, side]]
          return entry if entry
        end
        nil
      end

      def empty?
        @by_key.empty?
      end

      EMPTY = new.freeze

      private

      def ancestor_keys(class_name, kind, rbs_loader)
        if kind == :singleton
          pairs = rbs_loader ? rbs_loader.singleton_ancestors_for(class_name) : []
          pairs.empty? ? [[class_name, :singleton]] : pairs.map { |side, owner| [owner, side] }
        else
          names = rbs_loader ? rbs_loader.ancestor_names_for(class_name) : []
          (names.empty? ? [class_name] : names).map { |owner| [owner, :instance] }
        end
      end
    end
  end
end
