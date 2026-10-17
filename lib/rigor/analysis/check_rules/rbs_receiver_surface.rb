# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../dependency_recorder"
require_relative "../../inference/singleton_hook_decline"

module Rigor
  module Analysis
    module CheckRules
      # Issue #1722 — what the project may give an instance of an RBS-declared class beyond the class's RBS, asked
      # by `call.undefined-method` once the RBS lookup and the project's own tables for the class itself have come
      # back "absent". Three places the earlier probes do not look:
      #
      # - **A `method_missing` on an RBS ancestor.** `class Integer; def method_missing(*)` (or one on `Numeric`,
      #   `Comparable`, `Object`, `Kernel`, `BasicObject`, or a project module mixed into any of them) answers
      #   every name Ruby dispatches to an Integer. `respond_to_missing?` is not read: Ruby dispatches to
      #   `method_missing` whether or not it is defined.
      # - **A project mixin of the class or an RBS ancestor.** `Integer.include(Ext)` in another file, or
      #   `Comparable.include(Ext)` / `module Comparable; def zzz`, gives every Integer `zzz`. The earlier probes
      #   read the class's own chain through `discovered_methods`, which holds no plain `def` written in another
      #   file than the one being checked; this reads the def table too for a project module, and walks the
      #   ancestors RBS lists after the class. A cross-file `def` on an RBS-declared class or module itself stays
      #   ADR-17's monkey-patch report ({.mixin_defines?}). A project module whose `included` / `extended` hook may
      #   define methods on its includer answers any name. On `Object`, `Kernel` and `BasicObject` a project or
      #   RBS-declared module answers as anywhere else, but one neither declares does not: #1697's reading
      #   (`Inference::ObjectMixins`) is that such a module mixed into every object does not silence the rule.
      # - **A project subclass** ({.subclass_may_define?}). A value typed by its class's name through a signature
      #   (`#: () -> String`) may be an instance of any subclass, so a method a project subclass defines may be
      #   the one that runs.
      #
      # Each ancestor's name is filed as an ADR-46 class dependency, so a file that later reopens one re-checks
      # the call, and the subclass walk files a `subclass_of` edge per class it reads.
      module RbsReceiverSurface
        MISSING_HOOK = :method_missing
        # The roots whose project mixins `Inference::ObjectMixins` answers for.
        OBJECT_ROOTS = %w[Object Kernel BasicObject].to_set.freeze
        private_constant :MISSING_HOOK, :OBJECT_ROOTS

        module_function

        # Whether the project may answer `method_name` on an instance of `class_name` through one of its RBS
        # ancestors.
        def ancestor_may_answer?(scope, class_name, method_name)
          ancestor_names(scope, class_name).any? do |name|
            DependencyRecorder.read_last_segment(:class, name) if DependencyRecorder.active?
            next false unless scope.known_user_class?(name)

            chain_answers?(scope, name, method_name, unknown_answers: !OBJECT_ROOTS.include?(name))
          end
        end

        # Whether the singleton side of `class_name` may reach a project `method_missing`: a `def self.method_missing`
        # on the class or an RBS superclass, or an instance `method_missing` on `Class`, `Module`, `Object`,
        # `Kernel` or `BasicObject` (a class object is an instance of each).
        def singleton_hook?(scope, class_name)
          loader = scope.environment&.rbs_loader
          pairs = loader ? loader.singleton_ancestors_for(class_name.to_s) : []
          pairs = [[:singleton, class_name.to_s]] if pairs.empty?
          pairs.any? do |kind, name|
            DependencyRecorder.read_last_segment(:class, name) if DependencyRecorder.active?
            if kind == :singleton
              !scope.singleton_def_for(name, MISSING_HOOK).nil? ||
                scope.discovered_method?(name, MISSING_HOOK, :singleton)
            else
              scope.known_user_class?(name) && hook_on_chain?(scope, name)
            end
          end
        end

        # Whether a project subclass of `class_name`, at any depth, defines `method_name` (through its own
        # ancestry, which reaches its project mixins) or a `method_missing`. Its parent is read as written and
        # resolved the way the class header resolves it: the first project class the spelling can denote, else the
        # top-level name, which is the RBS class.
        def subclass_may_define?(scope, class_name, method_name)
          each_subclass(scope, class_name.to_s) do |subclass|
            return true if project_defines?(scope, subclass, method_name) ||
                           project_defines?(scope, subclass, MISSING_HOOK) ||
                           !scope.user_def_through_ancestors(subclass, method_name).first.nil? ||
                           scope.discovered_method_through_ancestors?(subclass, method_name, :instance)
          end
          false
        end

        def ancestor_names(scope, class_name)
          loader = scope.environment&.rbs_loader
          names = loader ? loader.ancestor_names_for(class_name.to_s) : []
          names.empty? ? [class_name.to_s] : names
        end

        # A search of `name`'s project chain for an entry that may answer: a project entry that defines
        # `method_name` or a `method_missing`, a project module whose hook may define methods on its includer, or
        # an external mixin RBS declares `method_name` on — or, when `unknown_answers`, one RBS does not know. A
        # chain cut at its budget may hold an answer past the cut.
        def chain_answers?(scope, name, method_name, unknown_answers:)
          chain = Scope::ResolutionChain.for(scope, name, :instance, :methods)
          found = chain.search(scope, side: :instance) do |entry|
            if entry.external?
              external_may_answer?(scope, entry, method_name, unknown_answers)
            else
              project_defines?(scope, entry.name, MISSING_HOOK) || mixin_defines?(scope, entry, method_name)
            end
          end
          found || chain.truncated?
        end

        # The singleton side's question of an instance chain: does a project entry on it define `method_missing`?
        def hook_on_chain?(scope, name)
          chain = Scope::ResolutionChain.for(scope, name, :instance, :methods)
          found = chain.search(scope, side: :instance) do |entry|
            !entry.external? && project_defines?(scope, entry.name, MISSING_HOOK)
          end
          found || chain.truncated?
        end

        def project_defines?(scope, owner, method_name)
          !scope.user_def_for(owner, method_name).nil? || scope.discovered_method?(owner, method_name, :instance)
        end

        # ADR-17 — a `def` the project writes on a class or module RBS declares (`class String; def x`, `module
        # Comparable; def x`) in another file than the call is a monkey-patch Rigor does not apply cross-file, and the
        # rule reports it with the `pre_eval:` advice, so on such an entry only what `discovered_methods` carries
        # answers. A project module's own `def` answers from any file.
        #
        # A project module's hook (`def self.included(base) = base.class_eval { def x }`, `base.send(:define_method,
        # …)`) defines methods on whatever mixes it in, so a module {Inference::SingletonHookDecline} reads as
        # hook-capable may answer any name.
        def mixin_defines?(scope, entry, method_name)
          owner = entry.name
          if Rigor::Reflection.rbs_class_known?(owner, scope: scope)
            scope.discovered_method?(owner, method_name, :instance)
          else
            project_defines?(scope, owner, method_name) ||
              Inference::SingletonHookDecline.entry_hook_capable?(scope, entry)
          end
        end

        def external_may_answer?(scope, entry, method_name, unknown_answers)
          candidates = entry.candidates
          return unknown_answers if candidates.empty?
          return true if candidates.any? do |candidate|
            Rigor::Reflection.instance_method_definition(candidate, method_name, scope: scope)
          end

          unknown_answers && candidates.none? { |candidate| Rigor::Reflection.rbs_class_known?(candidate, scope: scope) }
        end

        def each_subclass(scope, class_name)
          children = children_by_parent(scope)
          queue = children.fetch(class_name, []).dup
          seen = {}
          record_subclasses_read(class_name)
          until queue.empty?
            subclass = queue.shift
            next if seen[subclass]

            seen[subclass] = true
            record_subclasses_read(subclass)
            yield subclass
            queue.concat(children.fetch(subclass, []))
          end
        end

        def children_by_parent(scope)
          scope.discovered_superclasses.each_with_object({}) do |(child, raw_parent), children|
            next if raw_parent.nil?

            candidates = scope.ancestor_name_candidates(child, raw_parent.to_s)
            parent = candidates.find { |name| scope.known_user_class?(name) } || candidates.last
            (children[parent] ||= []) << child if parent
          end
        end

        def record_subclasses_read(class_name)
          return unless DependencyRecorder.active?

          DependencyRecorder.read_last_segment(:subclass_of, class_name)
        end
      end
    end
  end
end
