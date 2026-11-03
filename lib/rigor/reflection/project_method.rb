# frozen_string_literal: true

module Rigor
  # {Reflection}'s ancestor facade for plugins (ADR-128 WD1), split out for the reader rather than for the
  # loader: {.project_method_defined} turns the two `Scope` ancestor walks into one `Trinary` answer. Reopening
  # the module keeps it behind the facade its callers already read.
  module Reflection
    module_function

    PROJECT_METHOD_KINDS = %i[instance singleton].freeze
    PROJECT_METHOD_SOURCES = %i[def discovered either].freeze
    private_constant :PROJECT_METHOD_KINDS, :PROJECT_METHOD_SOURCES

    # ADR-128 WD1 — does the project define `method_name` on `class_name` or on an ancestor the project itself
    # declares? Answers a {Trinary}: `yes` where the walk found a definer, `no` where it walked the whole chain
    # and found none, and `maybe` where the walk's `ResolutionChain` was cut at its budget before it found one
    # (ADR-41 WD4), so a definer past the cut cannot be ruled out. It replaces a plugin's direct call to the
    # two `Scope` walks, whose budget answers differ and are not a promise to plugin authors.
    #
    # - `kind:` is `:instance` or `:singleton`; each walks its own chain.
    # - `source:` names the walk outright, with that walk's order and settling:
    #   - `:def` — the first project `def` (`Scope#user_def_through_ancestors`, or `#singleton_def_through_ancestors`
    #     for `kind: :singleton`). It does not count `attr_*` or `define_method`.
    #   - `:discovered` — the discovery table (`Scope#discovered_method_through_ancestors?`), which also counts
    #     `attr_*` and `define_method`.
    #   - `:either` — their union as a three-valued OR: `yes` wins, then `maybe`, then `no`.
    #
    # A site that tested the `:def` walk's old answer tests `.yes?` (that walk read a cut as absent); a site that
    # tested the `:discovered` walk's tests `!no?` (that walk read a cut as present).
    def project_method_defined(class_name, method_name, kind:, source:, scope:)
      raise ArgumentError, "unknown kind #{kind.inspect}" unless PROJECT_METHOD_KINDS.include?(kind)
      raise ArgumentError, "unknown source #{source.inspect}" unless PROJECT_METHOD_SOURCES.include?(source)

      case source
      when :def then project_def_defined(class_name, method_name, kind, scope)
      when :discovered then project_discovered_defined(class_name, method_name, kind, scope)
      else project_either_defined(class_name, method_name, kind, scope)
      end
    end

    # `yes` wins, then `maybe`, then `no`; the discovery walk only runs where the def walk did not already say `yes`.
    def project_either_defined(class_name, method_name, kind, scope)
      by_def = project_def_defined(class_name, method_name, kind, scope)
      return by_def if by_def.yes?

      by_def.or(project_discovered_defined(class_name, method_name, kind, scope))
    end
    private_class_method :project_either_defined

    # The def walk answers `[node, owner]` or `[nil, nil]`, and `[nil, nil]` both when the chain holds no definer
    # and when it was cut; the chain (memoised, so this is the one the walk read) tells the two apart.
    def project_def_defined(class_name, method_name, kind, scope)
      found = if kind == :singleton
                scope.singleton_def_through_ancestors(class_name, method_name)
              else
                scope.user_def_through_ancestors(class_name, method_name)
              end
      return Trinary.yes if found.first

      project_chain_truncated?(class_name, kind, scope) ? Trinary.maybe : Trinary.no
    end
    private_class_method :project_def_defined

    # The discovery walk answers `true` both for a definer and for a cut chain, so a `true` on a cut chain is
    # settled by searching the chain's entries for a definer, as the walk does.
    def project_discovered_defined(class_name, method_name, kind, scope)
      return Trinary.no unless scope.discovered_method_through_ancestors?(class_name, method_name, kind)
      return Trinary.yes unless project_chain_truncated?(class_name, kind, scope)

      chain = Scope::ResolutionChain.for(scope, class_name.to_s, kind, :methods)
      found = chain.search(scope) do |entry|
        next false if entry.external?

        scope.discovered_method?(entry.name, method_name, discovered_entry_kind(entry, kind))
      end
      found ? Trinary.yes : Trinary.maybe
    end
    private_class_method :project_discovered_defined

    # A singleton-side entry reads the singleton table; a module on the singleton chain answers with its
    # INSTANCE methods; on the instance chain the caller's kind stands (`Scope#kind_for`).
    def discovered_entry_kind(entry, kind)
      return :singleton if entry.side == :singleton

      kind == :singleton ? :instance : kind
    end
    private_class_method :discovered_entry_kind

    def project_chain_truncated?(class_name, kind, scope)
      Scope::ResolutionChain.for(scope, class_name.to_s, kind, :methods).truncated?
    end
    private_class_method :project_chain_truncated?
  end
end
