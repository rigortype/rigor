# frozen_string_literal: true

require_relative "builtins/cruby_definers"

module Rigor
  module Inference
    # ADR-121 WD2 (issue #1664) — which in-effect refinement, if any, answers a call on an instance of a class. The
    # typed refined arm (`ExpressionTyper#try_refined_dispatch`) asks it before every other answer, because those
    # answer from the method a refinement replaces.
    #
    # Precedence follows `doc/syntax/refinements.rdoc` § Method Lookup: walk the receiver's classes from the most
    # derived. At each class, the latest in-effect module refining the name for that class wins; otherwise its
    # prepended modules, its own method and its included modules answer in that order, and the refinement
    # declines; otherwise move on. A refinement of a module is decided where that module sits in the walk.
    #
    # The walk reads RBS ancestors for a class RBS knows (each ancestor a level of its own, so a core class's
    # prepends are not told apart), and the project's `Scope::ResolutionChain` levels for one only the project
    # declares, splicing in the RBS ancestors of the superclass it does not declare. "Defines the method" is an RBS
    # declaration on that class itself, or a project `def`, `attr_*` or `define_method` of it. Core RBS sometimes
    # redeclares an inherited method on a subclass, which stops the walk there: a known imprecision, in the
    # declining direction.
    module RefinedDispatch
      # The refinement that answers: `module_name` refines `refined_class` (a class or module on the walk).
      Winner = Data.define(:module_name, :refined_class)

      # The answer when the in-effect list carries {InEffectRefinements::UNKNOWN} and some refinement defines the
      # name on a class the walk reaches: any of them may answer.
      UNKNOWN = :unknown

      # {.decision}'s answer when the walk reaches a class or module that defines the name itself before any in-effect
      # refinement of it: the receiver's own method answers and shadows every refinement further up (issue #1740).
      SHADOWED = :shadowed

      module_function

      # A {Winner}, {UNKNOWN}, or nil when no in-effect refinement answers `method_name` on an instance of
      # `class_name` (the class's own lookup does). `list` is the call site's in-effect refinements.
      def winner(scope, class_name, method_name, list)
        answer = decision(scope, class_name, method_name, list)
        answer == SHADOWED ? nil : answer
      end

      # Issue #1740 — is `method_name` on an instance of `class_name` provably answered by the receiver's own lookup:
      # the walk reaches a definer before any refinement in effect in `list`? False wherever {.winner}'s nil rests on
      # anything weaker: no readable ancestry, no resolvable refined class, a project mixin of unknown position, a
      # definer {#own_definition} cannot prove, or an in-effect module whose refine bodies the project does not show
      # (a gem's `using GemRef`, whose `refine String` may define the name below the definer).
      def own_method_answers?(scope, class_name, method_name, list)
        return false unless refinements_visible?(scope.discovered_refinements, list)

        decision(scope, class_name, method_name, list) == SHADOWED
      end

      # Is every module in `list` one some discovered refine body belongs to? {InEffectRefinements::UNKNOWN} may be
      # any module, so it is not.
      def refinements_visible?(refinements, list)
        return false if list.include?(InEffectRefinements::UNKNOWN)

        refining = Set.new
        refinements.each_value { |methods| methods.each_value { |modules| refining.merge(modules) } }
        list.all? { |entry| refining.include?(entry) }
      end

      # {.winner}, with the nil that a definer reached first answers kept apart as {SHADOWED}.
      def decision(scope, class_name, method_name, list)
        targets = resolved(scope, targets(scope.discovered_refinements, method_name, list), method_name)
        unknown = list.include?(InEffectRefinements::UNKNOWN)
        return nil if targets.nil? && !unknown

        levels = levels(scope, class_name)
        return nil if levels.nil?
        return UNKNOWN if unknown && unknown_reaches?(scope.discovered_refinements, method_name, levels)
        return nil if targets.nil?

        walk(scope, levels, method_name, targets)
      end

      # `{refined class => the latest in-effect module refining method_name for it}`, or nil when none is in effect.
      def targets(refinements, method_name, list)
        out = nil
        refinements.each do |refined, methods|
          modules = methods[method_name]
          next if modules.nil?

          best = latest(modules, list)
          (out ||= {})[refined] = best if best
        end
        out
      end

      # The refinement table records every name a `refine` argument's spelling can denote (`refine String` inside
      # `module M` records `M::String` and `String`), which only withholds a check. To type, a key must be the class
      # Ruby's lexical lookup resolves: one the project or RBS knows, with no longer spelling of the same last segment
      # that the same module refines the name for and that is known too (that one is innermost, so it wins). Nil
      # when no key survives.
      def resolved(scope, targets, method_name)
        return nil if targets.nil?

        refinements = scope.discovered_refinements
        kept = targets.select do |refined, module_name|
          known_class?(scope, refined) && !shadowed?(scope, refinements, refined, module_name, method_name)
        end
        kept.empty? ? nil : kept
      end

      def shadowed?(scope, refinements, refined, module_name, method_name)
        suffix = "::#{refined.split('::').last}"
        depth = refined.count(":")
        refinements.any? do |other, methods|
          other.count(":") > depth && other.end_with?(suffix) && methods[method_name]&.include?(module_name) &&
            known_class?(scope, other)
        end
      end

      def known_class?(scope, name)
        scope.discovered_classes.key?(name) || scope.environment&.class_known?(name) || false
      end

      def latest(modules, list)
        best = nil
        best_index = -1
        modules.each do |module_name|
          index = list.index(module_name)
          next unless index && index > best_index

          best = module_name
          best_index = index
        end
        best
      end

      def unknown_reaches?(refinements, method_name, levels)
        levels.any? do |_level_class, entries|
          entries.any? { |entry| refinements[entry]&.key?(method_name) }
        end
      end

      # A level the project mixes a module into whose position RBS does not record (`mixed`) is decided by its own
      # refinement first, as any level is; past that, the mixin may define the name, so a refinement further up the
      # walk may or may not win and the answer is {UNKNOWN}, never the replaced method's.
      def walk(scope, levels, method_name, targets)
        levels.each_with_index do |(level_class, entries, mixed), index|
          refining = level_class && targets[level_class]
          return Winner.new(module_name: refining, refined_class: level_class) if refining
          return targeted_after?(levels, index, targets) ? UNKNOWN : nil if mixed

          entries.each_with_index do |entry, position|
            refining = entry == level_class ? nil : targets[entry]
            return Winner.new(module_name: refining, refined_class: entry) if refining
            return own_definition(scope, levels, index, position, method_name) if defines?(scope, entry, method_name)
          end
        end
        nil
      end

      # {SHADOWED} for the definer at `levels[index]`'s entry `position`, or nil when the walk cannot prove Ruby finds
      # the method there. A project `def`, `attr_*` or `define_method` is the method Ruby finds. An RBS declaration is
      # not: core RBS redeclares some inherited methods on a subclass (`Integer#quo`, `File#to_path`, whose CRuby owners
      # are `Numeric` and `IO`, so `refine Numeric do def quo(a, b, c)` makes `1.quo(1, 2, 3)` return 1 on Ruby 4.0.5)
      # and declares some CRuby no longer defines (`Process::Status#&`). It counts only where the offline CRuby
      # catalogue ({Builtins::CRubyDefiners}) lists the method on that class.
      def own_definition(scope, levels, index, position, method_name)
        entry = levels[index][1][position]
        return SHADOWED if scope.user_def_for(entry, method_name)
        return SHADOWED if scope.discovered_method?(entry, method_name, :instance)

        Builtins::CRubyDefiners.defines?(entry, method_name) ? SHADOWED : nil
      end

      def targeted_after?(levels, index, targets)
        levels.drop(index).any? { |_level_class, entries| entries.any? { |entry| targets.key?(entry) } }
      end

      # `[[level class, [entries in lookup order], mixed], …]` for an instance of `class_name`, or nil when the walk
      # cannot
      # be trusted: a chain cut at its limit, or one that records a mixin the tables cannot name.
      def levels(scope, class_name)
        environment = scope.environment
        return rbs_levels(scope, class_name) if environment&.class_known?(class_name)

        project_levels(scope, class_name)
      end

      # The RBS ancestors, each a level of its own, `mixed` where the project reopens one to mix a module in (`class
      # String; include Loud; end`), whose position among them RBS does not record. Each ancestor's name is a
      # dependency, so a file that adds such a reopening re-checks the consumer.
      def rbs_levels(scope, class_name)
        loader = scope.environment.rbs_loader
        names = loader ? loader.ancestor_names_for(class_name) : []
        names = [class_name] if names.empty?
        names.map { |name| [name, [name], project_mixin?(scope, name)] }
      end

      def project_mixin?(scope, name)
        Analysis::DependencyRecorder.read_last_segment(:class, name) if Analysis::DependencyRecorder.active?
        !scope.includes_of(name).empty? || scope.discovery.discovered_prepends.key?(name) ||
          (scope.discovered_classes.key?(name) &&
            Scope::ResolutionChain.for(scope, name, :instance, :methods).wildcard_mixin?)
      end

      def project_levels(scope, class_name)
        chain = Scope::ResolutionChain.for(scope, class_name, :instance, :methods)
        chain.record(scope) if Analysis::DependencyRecorder.active?
        return nil if chain.truncated? || chain.wildcard_mixin?

        out = []
        chain.level_count.times do |index|
          level_class = chain.level_classes[index]
          names = chain.level_entries(index).filter_map { |entry| entry_name(scope, entry) }
          next out << [level_class, names] if level_class

          names.each { |name| out.concat(rbs_levels(scope, name)) }
        end
        out
      end

      def entry_name(scope, entry)
        return entry.name unless entry.external?

        environment = scope.environment
        entry.candidates.find { |candidate| environment&.class_known?(candidate) }
      end

      # Does `name` define `method_name` on its instance side itself: a project `def` (its dependency edge recorded
      # through `Scope#user_def_for`), another project definer (`attr_*`, `define_method`), or an RBS declaration
      # written on `name` rather than on an ancestor?
      def defines?(scope, name, method_name)
        return true if scope.user_def_for(name, method_name)
        return true if scope.discovered_method?(name, method_name, :instance)

        definition = ExternalAncestorResolution.method_definition(name, method_name, :instance, scope: scope)
        ExternalAncestorResolution.declared_on_class?(definition, name)
      end
    end
  end
end
