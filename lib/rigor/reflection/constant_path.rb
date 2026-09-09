# frozen_string_literal: true

module Rigor
  # {Reflection}'s second constant-resolution phase, split out for the reader rather than for the
  # loader: `reflection.rb` asks what a whole spelling names under a series of prefixes, and this file
  # asks what a PATH names segment by segment. Reopening the module rather than nesting under it keeps
  # the walk inside the facade its callers already read, and lets it use the same private candidate
  # lookups (`constant_type_at`, `enclosing_class_path`, `ancestor_constant_scopes`) the ladder uses.
  module Reflection
    module_function

    # Issue #656 — Ruby's lookup for an as-written, unrooted constant PATH (`A::B`, `A::B::C`), which is
    # a different question from "what does this whole string name under some prefix". Ruby resolves the
    # FIRST segment through the ladder a bare name gets — `Module.nesting`, then the enclosing class's
    # ancestors, then the top level — and then resolves each LATER segment inside the constant the
    # previous segment produced, searching THAT constant's own ancestors in turn. So `A::B` written in
    # `P::Guard` with `P::A < P::Base` names `P::Base::B`, while every whole-path candidate
    # (`P::Guard::A::B`, `P::A::B`, `A::B`) either misses or names a real but different class.
    #
    # `known` decides the FINAL segment only, so the constant typer (any constant, values included) and
    # `Inference::Narrowing`'s class-guard resolver (classes only) share one walk without sharing an
    # acceptance test — the two cannot answer different names for the same spelling. Every earlier
    # segment must name a namespace, because only a namespace can own the next one.
    #
    # Returns nil for a single-segment name — the callers' own ladders already own that case — and the
    # moment any segment declines. Declining hands the caller back its unchanged fallback instead of a
    # guess: a walk that finds the WRONG constant is worse than the wrong constant answered today
    # (AGENTS.md § "Implementation Guidelines").
    #
    # Checked against MRI 4.0.5 rather than recollection: a later segment does NOT reach the top level
    # for either a Class or a Module owner (`P::Mod::B` raises `NameError` where a top-level `B`
    # exists), which is why {.constant_in_namespace} consults the owner's ancestors and stops. Rigor
    # still lets its callers fall through to their own top-level rung there — that read raises at
    # runtime and Rigor reports nothing about it either way, so retracting the resolution would trade a
    # silent wrong answer for a silent absent one at no gain (the same reasoning as
    # {.toplevel_first_constant_type}'s caller-derived rungs).
    def resolve_constant_path_name(name, scope, &known)
      segments = name.to_s.split("::")
      return nil unless segments.size > 1

      owner = path_head_owner(segments.first, scope)
      last = segments.size - 1
      segments.each_with_index do |segment, index|
        next if index.zero?
        return nil if owner.nil?

        owner = constant_in_namespace(owner, segment, scope) do |candidate|
          index == last ? known.call(candidate) : namespace_known?(candidate, scope)
        end
      end
      owner
    end

    # Step 2.5's rung as a type: the segment-wise name, then that name looked up like any other
    # candidate so the answer comes from the same source-precedence order as every other rung.
    def constant_path_type(name, scope)
      qualified = resolve_constant_path_name(name, scope) { |candidate| constant_type_at(candidate, scope) }
      qualified && constant_type_at(qualified, scope)
    end
    private_class_method :constant_path_type

    # The namespace a path's FIRST segment names — the bare-name ladder, restricted to answers that can
    # OWN the segments that follow. A value constant is not one of them, so it declines here rather
    # than producing a namespace prefix no source knows.
    def path_head_owner(head, scope)
      hit = first_namespace_hit(lexical_nesting_chain(scope), head, scope)
      return hit if hit

      prefix = enclosing_class_path(scope)
      unless prefix.nil? || prefix.empty?
        hit = first_namespace_hit(bounded_ancestor_scopes(prefix, scope), head, scope)
        return hit if hit
      end

      head if namespace_known?(head, scope)
    end
    private_class_method :path_head_owner

    # {.first_constant_hit}'s namespace twin: the first `<entry>::<name>` that can own further segments.
    def first_namespace_hit(entries, name, scope)
      entries.each do |entry|
        candidate = "#{entry}::#{name}"
        return candidate if namespace_known?(candidate, scope)
      end
      nil
    end
    private_class_method :first_namespace_hit

    # `segment` looked up inside `owner` and then through `owner`'s own ancestors — Ruby's lookup for
    # every segment after the first. `Object` is deliberately absent: MRI raises rather than reaching a
    # top-level constant through an explicit `::` receiver.
    def constant_in_namespace(owner, segment, scope)
      candidate = "#{owner}::#{segment}"
      return candidate if yield(candidate)

      bounded_ancestor_scopes(owner, scope).each do |ancestor|
        inherited = "#{ancestor}::#{segment}"
        return inherited if yield(inherited)
      end
      nil
    end
    private_class_method :constant_in_namespace

    # How many of {.ancestor_constant_scopes}' entries one segment may consult, under
    # `Scope::ANCESTOR_WALK_LIMIT` — the budget `Scope`'s method lookup already spends on this same
    # graph, reused rather than re-chosen so one pathological ancestry costs one bound. The list
    # itself is the memoised one step 2 builds, so this bounds the per-segment consultation the walk
    # adds and not the graph. Reported through the shared counter, so a truncated walk is visible in a
    # budget trace instead of looking like a plain miss.
    def bounded_ancestor_scopes(class_name, scope)
      scopes = ancestor_constant_scopes(class_name, scope)
      return scopes if scopes.size <= Scope::ANCESTOR_WALK_LIMIT

      Inference::BudgetTrace.hit(Inference::BudgetTrace::ANCESTOR_WALK_LIMIT)
      scopes.first(Scope::ANCESTOR_WALK_LIMIT)
    end
    private_class_method :bounded_ancestor_scopes

    # Whether `name` can OWN a constant. `class_known?` covers the RBS and registry classes and modules;
    # the project tables cover a namespace the project declares with no RBS for it.
    def namespace_known?(name, scope)
      scope.environment.class_known?(name) || known_project_namespace?(name, scope)
    end
    private_class_method :namespace_known?
  end
end
