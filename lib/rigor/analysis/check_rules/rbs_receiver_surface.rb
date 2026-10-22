# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../dependency_recorder"
require_relative "../../inference/singleton_hook_decline"
require_relative "../../inference/object_mixins"

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
      #   ADR-17's monkey-patch report ({.mixin_defines?}). A mixin with an open surface — a project module with a
      #   recorded `included` / `extended` / … hook, a `"*"` mixin or `ActiveSupport::Concern`, or one neither RBS nor
      #   the project declares — answers any name, except on `Object`, `Kernel` and `BasicObject`: there only a
      #   module that defines the name answers, #1697's reading (`Inference::ObjectMixins`) of a module mixed into
      #   every object.
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

            chain_answers?(scope, name, method_name, open_mixins: !OBJECT_ROOTS.include?(name))
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

        # Issue #2094 — the singleton side's twin of {.ancestor_may_answer?}: a module the class or an RBS superclass
        # `extend`s (in its body, as `Float.extend(Ext)`, or as `Float.singleton_class.include(Ext)`) may answer
        # `method_name` on the class object, read as {.mixin_defines?} / {.external_may_answer?} read an instance-side
        # mixin. Only each level's own singleton segment is read: the class's further singleton ancestors are the
        # RBS superclasses this walk visits in turn, and `Class` / `Module` are {.singleton_hook?}'s.
        def singleton_mixin_may_answer?(scope, class_name, method_name)
          singleton_class_names(scope, class_name).any? do |name|
            DependencyRecorder.read_last_segment(:class, name) if DependencyRecorder.active?

            extends_answer?(scope, name, method_name, open_mixins: !OBJECT_ROOTS.include?(name))
          end
        end

        def singleton_class_names(scope, class_name)
          loader = scope.environment&.rbs_loader
          pairs = loader ? loader.singleton_ancestors_for(class_name.to_s) : []
          names = pairs.filter_map { |kind, name| name if kind == :singleton }
          names.empty? ? [class_name.to_s] : names
        end

        def extends_answer?(scope, name, method_name, open_mixins:)
          chain = Scope::ResolutionChain.for(scope, name, :singleton, :methods)
          return true if chain.truncated?
          # A mixin call the indexer could not record (`Integer.extend(m)`, `Symbol.singleton_class.send(:include,
          # M)`) leaves the side tainted: some module the tables do not name may answer any name.
          return true if open_mixins && chain.wildcard_mixin?

          entries = chain.level_count.zero? ? chain.entries : chain.level_entries(0)
          entries.any? do |entry|
            if entry.external?
              external_may_answer?(scope, entry, method_name, open_mixins)
            else
              entry.name != name && mixin_defines?(scope, entry, method_name, open_mixins)
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
        # `method_name` or a `method_missing`, or an external mixin RBS declares `method_name` on. When
        # `open_mixins` (every ancestor but `Object`, `Kernel` and `BasicObject`, #1697), also a mixin whose surface
        # is open: a project module SingletonHookDecline reads as hook-capable, or an external neither RBS nor the
        # project declares. A chain cut at its budget may hold an answer past the cut.
        def chain_answers?(scope, name, method_name, open_mixins:)
          chain = Scope::ResolutionChain.for(scope, name, :instance, :methods)
          found = chain.search(scope, side: :instance) do |entry|
            if entry.external?
              external_may_answer?(scope, entry, method_name, open_mixins)
            else
              project_defines?(scope, entry.name, MISSING_HOOK) ||
                mixin_defines?(scope, entry, method_name, open_mixins)
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
        # When `open_mixins`, a project module {Inference::SingletonHookDecline} reads as hook-capable — one that
        # records an `included` / `extended` / … hook (`def self.included(base) = base.class_eval { def x }`), lists
        # a `"*"` mixin, or extends `ActiveSupport::Concern` — may answer any name.
        def mixin_defines?(scope, entry, method_name, open_mixins)
          owner = entry.name
          if Rigor::Reflection.rbs_class_known?(owner, scope: scope)
            scope.discovered_method?(owner, method_name, :instance)
          else
            project_defines?(scope, owner, method_name) || macro_names?(scope, owner, method_name) ||
              (open_mixins && (Inference::SingletonHookDecline.entry_hook_capable?(scope, entry) ||
                               open_extend?(scope, owner)))
          end
        end

        # Issue #2094 — a class-body macro of the module names the method ({Inference::ObjectMixins.macro_named?}).
        # Answers the named method only, so it holds on `Object`, `Kernel` and `BasicObject` too, where a module
        # that defines the name answers.
        def macro_names?(scope, owner, method_name)
          Inference::ObjectMixins.macro_named?(scope, owner, method_name)
        end

        # Issue #2094 — the module `extend`s a module whose surface is open: one neither RBS nor the project declares
        # (a gem's DSL with no signatures), or a project module {Inference::SingletonHookDecline} reads as
        # hook-capable. Any macro the module's body calls may come from it and define any name, and its `extended`
        # hook may too, so the module answers any name, the reading an undeclared `include` already gets. A chain cut
        # at its budget may hold such a module past the cut.
        def open_extend?(scope, owner)
          chain = Scope::ResolutionChain.for(scope, owner, :singleton, :methods)
          return true if chain.truncated?

          entries = chain.level_count.zero? ? chain.entries : chain.level_entries(0)
          entries.any? { |extended| Inference::SingletonHookDecline.entry_hook_capable?(scope, extended) }
        end

        # An external the project declares (a module with no `def`, which the chain does not hold as a project entry)
        # is known, and answers through RBS, or through what its own body's macros and `extend`s may define (issue
        # #2094: {.macro_names?} and {.open_extend?}, asked of each candidate the project declares).
        def external_may_answer?(scope, entry, method_name, open_mixins)
          candidates = entry.candidates
          return open_mixins if candidates.empty?
          return true if candidates.any? do |candidate|
            Rigor::Reflection.instance_method_definition(candidate, method_name, scope: scope)
          end
          return true if candidates.any? do |candidate|
            macro_names?(scope, candidate, method_name) || (open_mixins && open_extend?(scope, candidate))
          end

          open_mixins && candidates.none? { |candidate| declared?(scope, candidate) }
        end

        def declared?(scope, name)
          scope.discovered_classes.key?(name) || Rigor::Reflection.rbs_class_known?(name, scope: scope)
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
