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

      module_function

      # A {Winner}, {UNKNOWN}, or nil when no in-effect refinement answers `method_name` on an instance of
      # `class_name` (the class's own lookup does). `list` is the call site's in-effect refinements.
      def winner(scope, class_name, method_name, list)
        targets = targets(scope.discovered_refinements, method_name, list)
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

      def walk(scope, levels, method_name, targets)
        levels.each do |level_class, entries|
          refining = level_class && targets[level_class]
          return Winner.new(module_name: refining, refined_class: level_class) if refining

          entries.each do |entry|
            refining = entry == level_class ? nil : targets[entry]
            return Winner.new(module_name: refining, refined_class: entry) if refining
            return nil if defines?(scope, entry, method_name)
          end
        end
        nil
      end

      # `[[level class, [entries in lookup order]], …]` for an instance of `class_name`, or nil when the walk cannot
      # be trusted: a chain cut at its limit, or one that records a mixin the tables cannot name.
      def levels(scope, class_name)
        environment = scope.environment
        return rbs_levels(environment, class_name) if environment&.class_known?(class_name)

        project_levels(scope, class_name)
      end

      def rbs_levels(environment, class_name)
        loader = environment.rbs_loader
        names = loader ? loader.ancestor_names_for(class_name) : []
        names = [class_name] if names.empty?
        names.map { |name| [name, [name]] }
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

          names.each { |name| out.concat(rbs_levels(scope.environment, name)) }
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
