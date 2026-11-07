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
    # declares? Answers a {Trinary}: `yes` where the walk found a definer, `no` where it found none and its
    # `ResolutionChain` was not truncated, and `maybe` where the chain was truncated at its budget before it found one
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

    # Does RBS declare `method_name` on `class_name` or on an ancestor the project's own ancestry reaches? A
    # project class (`class ArticlesController < ActionController::Base`) is rarely in RBS itself; its RBS-known
    # ancestors are the EXTERNAL entries of its `ResolutionChain`, which the RBS-only reads
    # ({.instance_method_definition}) cannot reach from the project class's name. This walks the chain and asks RBS
    # of each entry (every candidate spelling of an external one), on the side the entry sits.
    #
    # Answers a {Trinary}: `yes` when an entry's RBS declares the method, `no` when none does and the chain was
    # not truncated, `maybe` when the chain was cut at its budget (ADR-41 WD4) before one did. `kind:` is
    # `:instance` or `:singleton`; a `nil` `class_name` answers `no`.
    def rbs_method_defined(class_name, method_name, kind:, scope:)
      chain = ancestry_chain(class_name, kind, scope)
      return Trinary.no if chain.nil?

      found = chain.search(scope) do |entry|
        chain_entry_names(entry).any? { |name| !rbs_method_on_side(name, method_name, entry.side, scope).nil? }
      end
      chain_answer(found, chain)
    end

    # Does the project ancestry of `class_name` reach any of `ancestor_names` (qualified names, a leading `::`
    # ignored)? An external ancestor counts by any candidate spelling, so a superclass the project names but
    # does not declare (`ActionController::Base`, with no RBS loaded) is found. Same `Trinary` and `kind:` as
    # {.rbs_method_defined}.
    def ancestry_reaches(class_name, ancestor_names, kind:, scope:)
      chain = ancestry_chain(class_name, kind, scope)
      return Trinary.no if chain.nil?

      wanted = ancestor_names.map { |name| name.to_s.delete_prefix("::") }
      found = chain.search(scope) do |entry|
        chain_entry_names(entry).any? { |name| wanted.include?(name.to_s.delete_prefix("::")) }
      end
      chain_answer(found, chain)
    end

    def ancestry_chain(class_name, kind, scope)
      raise ArgumentError, "unknown kind #{kind.inspect}" unless PROJECT_METHOD_KINDS.include?(kind)
      return nil if class_name.nil?

      Scope::ResolutionChain.for(scope, class_name.to_s, kind, :methods)
    end
    private_class_method :ancestry_chain

    def chain_answer(found, chain)
      return Trinary.yes if found

      chain.truncated? ? Trinary.maybe : Trinary.no
    end
    private_class_method :chain_answer

    def chain_entry_names(entry)
      entry.external? ? entry.candidates : [entry.name]
    end
    private_class_method :chain_entry_names

    def rbs_method_on_side(class_name, method_name, side, scope)
      if side == :singleton
        singleton_method_definition(class_name, method_name, scope: scope)
      else
        instance_method_definition(class_name, method_name, scope: scope)
      end
    end
    private_class_method :rbs_method_on_side

    # `yes` wins, then `maybe`, then `no`. The early return is a short-circuit and carries no answer of its own:
    # `yes.or(x)` is `yes`, so removing it changes only which walks run, and so which dependencies they read.
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
      # A shortcut, not a decision: on an untruncated chain the search below finds the same definer.
      return Trinary.yes unless project_chain_truncated?(class_name, kind, scope)

      chain = Scope::ResolutionChain.for(scope, class_name.to_s, kind, :methods)
      found = chain.search(scope) do |entry|
        # A guard, not a decision: it mirrors `Scope#discovered_method_through_ancestors?`, whose search skips
        # an external entry (no project name to look up). `discovered_method?(nil, ...)` is false anyway.
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
