# frozen_string_literal: true

module Rigor
  module Inference
    module RefinedDispatch
      # Issue #1752 — the lookup of a class object, which Ruby walks like any object's: a refinement of `Object`,
      # `Module`, `Class`, `Kernel` or `BasicObject` answers `Integer.oo`, because a class object is an `Object`.
      #
      # The walk is `C`'s singleton class with the modules it extends, then each superclass's singleton class with its
      # extends, then the instance levels of `Class` (a class only), `Module`, `Object`, `Kernel` and `BasicObject`.
      # A singleton class is a level whose own entry is a {SingletonClass}: a refinement table key names an instance
      # side, so it never matches one (`refine C.singleton_class` records a class-unknown row), and it defines the
      # name through its own singleton methods. An extended module is an instance-side entry, so `refine(Ext)`
      # answers `C.z` where `C` extends `Ext` (Ruby 4.0.5).
      #
      # Every place the walk cannot read makes the whole walk unreadable (nil), where each reader declines: a chain
      # cut at its limit or holding a mixin the tables cannot name, a superclass the tables do not know (`class K <
      # <expr>`, `K = Class.new(Parent)`, an external superclass RBS does not declare), and a class some constant write
      # may have made (`Point = Struct.new(:x)`, whose superclass the tables do not record).
      module ClassObject
        EMPTY = [].freeze
        # The classes on every class object's lookup: the instance sides that hold `Class#new`, `Module#name` and
        # `Object#tap`. A class no table places among them may still be one a class object reaches only when it is a
        # module or a class the walk cannot place (`ClassObject.reachable?`).
        TAIL_CLASSES = %w[Class Module Object Kernel BasicObject].freeze
        private_constant :EMPTY

        module_function

        # `[[level class, entries, mixed, every entry], …]` in {RefinedDispatch.levels}' shape for the class object
        # `class_name`, or nil when the walk cannot be read. A singleton level's class is a {SingletonClass}.
        def levels(scope, class_name)
          return rbs_levels(scope, class_name) if scope.environment&.class_known?(class_name)

          project_levels(scope, class_name)
        end

        # RBS's singleton ancestry: each singleton class a level of its own, `mixed` where the project extends it at
        # a position RBS does not record, and each instance side (a declared `extend`, `Class`, `Module`, …) a level
        # read as the instance walk reads one. `from` drops the leading singleton classes a project level already
        # holds.
        def rbs_levels(scope, class_name, from: 0)
          loader = scope.environment&.rbs_loader
          pairs = loader ? loader.singleton_ancestors_for(class_name) : EMPTY
          return nil if pairs.empty?

          pairs.drop(from).map do |kind, name|
            next [name, [name], RefinedDispatch.project_mixin?(scope, name)] if kind == :instance

            own = SingletonClass.new(name)
            [own, [own], singleton_mixin?(scope, name)]
          end
        end

        # The project's singleton-side `Scope::ResolutionChain` (`C`'s singleton, its `extend`s' instance chains,
        # then each project superclass's), spliced into RBS's singleton ancestry at an external superclass, or
        # followed by the implicit tail after the last project class.
        def project_levels(scope, class_name)
          chain = Scope::ResolutionChain.for(scope, class_name, :singleton, :methods)
          chain.record(scope) if Analysis::DependencyRecorder.active?
          return nil if chain.truncated? || chain.wildcard_mixin? || chain.level_count.zero?

          out = []
          chain.level_count.times do |index|
            level_class = chain.level_classes[index]
            return splice_external(scope, out, chain.level_entries(index)) if level_class.nil?

            own = SingletonClass.new(level_class)
            every = chain.level_entries(index).map { |entry| level_entry(scope, entry, own) }
            out << [own, every.grep_v(Array), false, every]
          end
          tail = implicit_tail(scope, chain.level_classes[chain.level_count - 1])
          tail && out.concat(tail)
        end

        def level_entry(scope, entry, own)
          return own if !entry.external? && entry.side == :singleton && entry.name == own.of
          return SingletonClass.new(entry.name) if !entry.external? && entry.side == :singleton

          RefinedDispatch.entry_name(scope, entry) || RefinedDispatch.unnamed(entry)
        end

        # An external superclass stands for its whole singleton ancestry, which RBS gives when it declares the class.
        def splice_external(scope, out, entries)
          external = entries.find(&:external?)
          name = external&.candidates&.find { |candidate| scope.environment&.class_known?(candidate) }
          tail = name && rbs_levels(scope, name)
          tail && out.concat(tail)
        end

        # What follows the last project class on the walk: `Module` onwards for a module; RBS's singleton ancestry
        # past the class's own singleton for a class RBS declares (a reopened core class, a `sig/` class);
        # `Object`'s for a class with no superclass written. Nil where the superclass is not known: one the tables
        # record as unknown, and one a constant write may have given the class (a class only a constant write names
        # carries no superclass entry, and a reopening keeps the superclass that write made).
        def implicit_tail(scope, name)
          return RefinedDispatch.rbs_levels(scope, "Module") if module?(scope, name)
          return nil if unknown_superclass?(scope, name)
          return rbs_levels(scope, name, from: 1) if scope.environment&.class_known?(name)

          rbs_levels(scope, "Object")
        end

        def module?(scope, name)
          scope.discovered_parameter_envelopes[name]&.key?(Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK) ||
            scope.environment&.rbs_module?(name) || false
        end

        def unknown_superclass?(scope, name)
          superclasses = scope.discovered_superclasses
          return true if superclasses.key?(name) && superclasses[name].nil?
          return true if scope.discovered_parameter_envelopes[name]&.key?(
            Scope::DiscoveryIndex::ENVELOPE_META_SUPERCLASS_MARK
          )

          Analysis::DependencyRecorder.read_last_segment(:constant, name) if Analysis::DependencyRecorder.active?
          !scope.bound_constant_names(name).empty?
        end

        # Does the project mix a module into `name`'s singleton class, at a position RBS does not record?
        def singleton_mixin?(scope, name)
          Analysis::DependencyRecorder.read_last_segment(:class, name) if Analysis::DependencyRecorder.active?
          return true if scope.discovered_extends.key?(name)

          scope.discovered_classes.key?(name) &&
            Scope::ResolutionChain.for(scope, name, :singleton, :methods).wildcard_mixin?
        end

        # Does the singleton class of `name` define `method_name` itself: a singleton method the project writes in
        # `name`'s own body (`def self.x`, `class << self`, an `attr_*` there), or one RBS declares on `name`'s
        # singleton? A method the extends fold copied onto the singleton from a module `name` extends is that
        # module's, found where the module sits.
        def defines?(scope, name, method_name)
          return true if own_singleton_definer?(scope, name, method_name)

          definition = ExternalAncestorResolution.method_definition(name, method_name, :singleton, scope: scope)
          ExternalAncestorResolution.declared_on_class?(definition, name)
        end

        # A singleton `def` is the class's own unless it is the def a module the class extends holds, which the extends
        # fold copied ({.fold_copy?}). A singleton name without a node of its own (`attr_reader` in `class << self`,
        # `define_singleton_method`) counts when the class's envelope table records it, which the fold never writes.
        def own_singleton_definer?(scope, name, method_name)
          node = scope.singleton_def_for(name, method_name)
          return true if node && !fold_copy?(scope, name, method_name)
          return false unless scope.discovered_method?(name, method_name, :singleton)

          node.nil? || scope.parameter_envelopes_of(name).key?([:singleton, method_name.to_sym])
        end

        # Is `name`'s singleton `def` of the name the receiverless instance `def` of the module its `Module.nesting`
        # starts with, which the extends fold copied? The node is that module's own
        # (`SingletonHookDecline.copied_from?`), or, where the two tables came from two parses of the file, one with
        # its location and text, and no site of a singleton `def` of the name is recorded for `name` (the fold copies
        # nodes, not sites).
        def fold_copy?(scope, name, method_name)
          head = SingletonHookDecline.def_head(scope, name, method_name)
          return false if head.nil? || head == name
          return true if SingletonHookDecline.copied_from?(scope, head, method_name, name)

          node = scope.singleton_def_for(name, method_name)
          source = scope.user_def_for(head, method_name)
          !node.nil? && node.receiver.nil? && !source.nil? && same_def?(node, source) &&
            scope.discovery.discovered_singleton_def_sources.dig(name, method_name.to_sym).nil?
        end

        def same_def?(node, other)
          node.location.start_offset == other.location.start_offset &&
            node.location.end_offset == other.location.end_offset && node.slice == other.slice
        end

        # The typed arm's answer at a singleton level: {Winner}, {UNKNOWN}, nil (the class object's own lookup
        # answers) or `:continue`. The tables record `class << self; prepend M` (and `singleton_class.prepend(M)`) as
        # an `extend`, so a module on the level may sit ahead of the singleton class or of another module: one entry
        # that answers decides, several that answer decide only when none of them is refined.
        def walk_level(scope, entries, method_name, targets, unread)
          answers = entries.filter_map { |entry| entry_answer(scope, entry, method_name, targets, unread) }
          return :continue if answers.empty?
          return answers.first.answer if answers.size == 1

          answers.all? { |answer| answer.answer.nil? } ? nil : UNKNOWN
        end

        Answer = Data.define(:answer)
        private_constant :Answer

        def entry_answer(scope, entry, method_name, targets, unread)
          unless entry.is_a?(SingletonClass)
            return Answer.new(UNKNOWN) if unread.key?(entry)

            refining = targets[entry]
            return Answer.new(Winner.new(module_name: refining, refined_class: entry)) if refining
          end
          Answer.new(nil) if RefinedDispatch.defines?(scope, entry, method_name)
        end

        # Every class and module whose refinements a call on the class object `class_name` may reach, for
        # `call.undefined-method`'s decline: each name on the levels (an unnamed entry's candidates included), the
        # RBS ancestry of a module an extend names that the project does not declare, and the modules the project
        # mixes into a `mixed` level. Nil when the walk, or a `mixed` level's own chain, cannot be read.
        def reach(scope, class_name)
          levels = levels(scope, class_name)
          return nil if levels.nil?

          names = Set.new
          levels.each do |level_class, entries, mixed, every|
            (every || entries).each { |entry| add_reach(scope, names, entry) }
            next unless mixed
            return nil unless mixins_added?(scope, names, level_class)
          end
          names
        end

        def add_reach(scope, names, entry)
          return names.merge(entry) if entry.is_a?(Array)
          return if entry.is_a?(SingletonClass)

          names << entry
          return if scope.discovered_classes.key?(entry)

          loader = scope.environment&.rbs_loader
          names.merge(loader.ancestor_names_for(entry)) if loader
        end

        # The modules the project mixes into a `mixed` level's class, from its own chain on the level's side.
        def mixins_added?(scope, names, level_class)
          name, side = level_class.is_a?(SingletonClass) ? [level_class.of, :singleton] : [level_class, :instance]
          chain = Scope::ResolutionChain.for(scope, name, side, :methods)
          chain.record(scope) if Analysis::DependencyRecorder.active?
          return false if chain.truncated? || chain.wildcard_mixin?

          chain.entries.each do |entry|
            next names.merge(entry.candidates) if entry.external?

            names << entry.name if entry.side == :instance
          end
          true
        end

        # Can a refined-class key sit on some class object's lookup the walk could not read? Every class object
        # reaches the {TAIL_CLASSES} and whatever modules it extends, so only a class known to be none of those is
        # out of reach: a project class that is not a module, or one RBS declares as a class. A key nothing declares
        # may be a module.
        def reachable?(scope, key)
          return true if TAIL_CLASSES.include?(key)
          return false if scope.discovered_classes.key?(key) && !module?(scope, key)

          environment = scope.environment
          !(environment&.class_known?(key) && !environment.rbs_module?(key))
        end
      end
    end
  end
end
