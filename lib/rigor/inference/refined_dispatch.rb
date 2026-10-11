# frozen_string_literal: true

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

      NO_TARGETS = {}.freeze
      private_constant :NO_TARGETS

      module_function

      # `Scope::DiscoveryIndex::REFINEMENT_WILDCARD`, read when asked: this file loads before `Scope`.
      def wildcard = Scope::DiscoveryIndex::REFINEMENT_WILDCARD

      # A {Winner}, {UNKNOWN}, or nil when no in-effect refinement answers `method_name` on an instance of
      # `class_name` (the class's own lookup does). `list` is the call site's in-effect refinements.
      #
      # ADR-121 WD7 — a row the walk could not read never yields a {Winner}: an in-effect module's row for the name
      # whose class the walk could not name reaches every receiver, and a names-wildcard row of a level the walk
      # reaches before a definer may define the name, so both answer {UNKNOWN}. So does a winner whose module shares
      # its last segment with another listed module (A1): which of a `using`'s declared candidates Ruby finds can
      # depend on load order.
      def winner(scope, class_name, method_name, list)
        refinements = scope.discovered_refinements
        return UNKNOWN if class_unknown_row?(scope, refinements, method_name, list)

        targets = resolved(scope, targets(refinements, method_name, list), method_name)
        unread = targets(refinements, wildcard, list)
        unknown = list.include?(InEffectRefinements::UNKNOWN)
        return nil if targets.nil? && unread.nil? && !unknown

        levels = levels(scope, class_name)
        return nil if levels.nil?
        return UNKNOWN if unknown && unknown_reaches?(scope, refinements, method_name, levels)

        walk_targets(scope, levels, method_name, [targets, unread], list)
      end

      def walk_targets(scope, levels, method_name, (targets, unread), list)
        return nil if targets.nil? && unread.nil?

        answer = walk(scope, levels, method_name, targets || NO_TARGETS, unread || NO_TARGETS)
        answer.is_a?(Winner) && rival_spelling?(answer.module_name, list) ? UNKNOWN : answer
      end

      # ADR-121 WD7 (A2) — does an in-effect module have a row for `method_name` (or a names-wildcard row) whose
      # class the walk could not name ({InEffectRefinements.class_wildcard_key?})? It may refine the receiver's class.
      def class_unknown_row?(scope, refinements, method_name, list)
        refinements.any? do |refined, methods|
          rows = [methods[method_name], methods[wildcard]].compact
          !rows.empty? && rows.any? { |modules| in_effect?(modules, list) } &&
            InEffectRefinements.class_wildcard_key?(scope, refined)
        end
      end

      # Is one of `modules` (a row's refining modules) in `list`? The wildcard module, which the walk could not name,
      # is any listed module.
      def in_effect?(modules, list)
        return list.any? { |name| name != InEffectRefinements::UNKNOWN } if modules.include?(wildcard)

        modules.any? { |name| list.include?(name) }
      end

      def rival_spelling?(module_name, list)
        segment = module_name.split("::").last
        list.any? { |other| other.is_a?(String) && other != module_name && other.split("::").last == segment }
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

      # ADR-121 WD7 — a names-wildcard row counts as a row for every name, and a row whose class the walk could not
      # name reaches every level.
      def unknown_reaches?(scope, refinements, method_name, levels)
        unread_class = refinements.any? do |refined, methods|
          (methods.key?(method_name) || methods.key?(wildcard)) &&
            InEffectRefinements.class_wildcard_key?(scope, refined)
        end
        return true if unread_class

        levels.any? do |_level_class, entries|
          entries.any? do |entry|
            methods = refinements[entry]
            !methods.nil? && (methods.key?(method_name) || methods.key?(wildcard))
          end
        end
      end

      # A level the project mixes a module into whose position RBS does not record (`mixed`) is decided by its own
      # refinement first, as any level is; past that, the mixin may define the name, so a refinement further up the
      # walk may or may not win and the answer is {UNKNOWN}, never the replaced method's. ADR-121 WD7: a level an
      # in-effect module has a names-wildcard row for (`unread`) may define the name too, so it answers {UNKNOWN}.
      def walk(scope, levels, method_name, targets, unread)
        levels.each_with_index do |(level_class, entries, mixed), index|
          return UNKNOWN if level_class && unread.key?(level_class)

          refining = level_class && targets[level_class]
          return Winner.new(module_name: refining, refined_class: level_class) if refining
          return targeted_after?(levels, index, targets, unread) ? UNKNOWN : nil if mixed

          answer = walk_entries(scope, entries, level_class, method_name, targets, unread)
          return answer unless answer == :continue
        end
        nil
      end

      # A level's prepended modules, its own method and its included modules, in that order: `:continue` when none
      # answers, so the walk moves on.
      def walk_entries(scope, entries, level_class, method_name, targets, unread)
        entries.each do |entry|
          unless entry == level_class
            return UNKNOWN if unread.key?(entry)

            refining = targets[entry]
            return Winner.new(module_name: refining, refined_class: entry) if refining
          end
          return nil if defines?(scope, entry, method_name)
        end
        :continue
      end

      def targeted_after?(levels, index, targets, unread)
        levels.drop(index).any? do |_level_class, entries|
          entries.any? { |entry| targets.key?(entry) || unread.key?(entry) }
        end
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
