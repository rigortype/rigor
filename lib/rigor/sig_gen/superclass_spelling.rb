# frozen_string_literal: true

module Rigor
  module SigGen
    # Renders a recorded superclass token into the spelling that goes on an emitted `class` header.
    #
    # Issue [#609](https://github.com/rigortype/rigor/issues/609): every token that survives
    # {Generator#demote_unresolvable_superclasses} names a class the RBS environment or this run declares at an
    # ABSOLUTE position — both guards ask `Reflection.rbs_class_known?` and the emitted-name set, and both are
    # keyed by fully qualified name. The writer then emitted that token bare inside a nested `module` tree, where
    # RBS resolves its first segment relatively against the enclosing namespaces, so `class Show < Help::Show`
    # written under `module Views; module Help` re-points at `::Views::Help::Show` — the class being declared.
    # The self-referential ancestry is what made `AncestorBuilder#singleton_ancestors` recurse until the stack
    # was exhausted on the reporter's project, and what `RBS::RecursiveAncestorError` collapses the class over on
    # a smaller one. Anchoring the token with `::` says the name the guards already checked.
    module SuperclassSpelling
      module_function

      # @param token — a recorded superclass token, possibly carrying type arguments (`Foo::Bar[untyped]`).
      def absolute(token)
        return token if token.nil? || token.start_with?("::")

        "::#{token}"
      end
    end
  end
end
