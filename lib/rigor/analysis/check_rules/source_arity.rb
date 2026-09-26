# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../../source/parameter_envelope"

module Rigor
  module Analysis
    module CheckRules
      # Issue #992 — the positional envelope `call.wrong-arity` may check a call against when no signature
      # declares the method: the {Source::ParameterEnvelope} the project's own `def` records in
      # `Scope::DiscoveryIndex#discovered_parameter_envelopes`, and only when nothing the project can see
      # could make a different definition of that name the one that runs.
      #
      # Asked in two stages, because every condition past the first can only WITHHOLD a firing:
      #
      # 1. {#owner_envelope} walks the receiver's superclass chain to the first class whose own body, or one of
      #    whose project mixins, records the name. Every record at that level must agree — `include` and
      #    `prepend` share one table, so a mixin's definition may shadow the class's own — and none may be
      #    opaque. A call that fits this envelope is silent, and nothing below is consulted.
      # 2. {#authoritative?} runs only for a call that would fire. It declines when a `method_missing` /
      #    `respond_to_missing?` hook or a dynamic-surface mark sits anywhere in the chain; when a mixin the
      #    project does not declare is not a known RBS module that lacks the name; when a `pre_eval:` patch or
      #    a plugin's synthetic method names it; when the owner does not make the method public; and when any
      #    project subclass of the receiver — whose instances the receiver's type admits — records a different
      #    or opaque envelope for it.
      #
      # Deliberately NOT in scope: a constructor reached through `Class#new` (nothing records `initialize` as
      # `[:singleton, :new]`, so `.new` finds no owner unless the class writes `def self.new` itself); keyword
      # arity (the envelope's required-keyword flag declines, as `compute_arity_envelope` declines an RBS
      # function with required keywords); and a `class_eval` whose receiver is not a constant, which the
      # discovery walk cannot name.
      class SourceArity
        MISSING_HOOKS = %i[method_missing respond_to_missing?].freeze
        private_constant :MISSING_HOOKS

        # One class on the walk: its own name, the project modules its mixins resolve to (transitively through
        # their own `include`s), and the candidate-name lists of the mixins that resolve to no project module.
        Level = Data.define(:class_name, :modules, :externals)
        private_constant :Level

        def initialize(scope, method_name, kind)
          @scope = scope
          @method_name = method_name.to_sym
          @kind = kind
          @name_memo = {}
        end

        # The nearest definition's envelope, or nil when there is none or it is not one shape. Remembers the
        # levels it walked for {#authoritative?}.
        #
        # Its ADR-46 reads are withheld ({Analysis::DependencyRecorder.withhold}) until the caller settles
        # the verdict with {#settle_by_definitions} or {#settle_by_walk}.
        def owner_envelope(class_name)
          @owner_entries = []
          @ambiguous = false
          envelope, @withheld = Analysis::DependencyRecorder.withhold { walk_to_owner(class_name) }
          envelope
        end

        # True when the nearest level recorded the name but not as one envelope.
        def ambiguous? = @ambiguous

        # For a silent verdict that only a definition can overturn — the call fits, the owner takes a required
        # keyword, or nothing on the chain records the name: the owner `def`s themselves (their symbol edges)
        # and a definition appearing at a level the walk passed over (a name-keyed negative edge). A mixin or
        # reopening added at the owner's level makes it opaque, and everything {#authoritative?} reads can only
        # withhold, so none of these needs the file-level class edge the bucket reads would otherwise record.
        def settle_by_definitions
          return if @withheld.nil?

          @owner_entries.each do |name, kind|
            if kind == :singleton
              @scope.user_singleton_def_site_for(name, @method_name)
            else
              @scope.user_def_site_for(name, @method_name)
            end
          end
          separator = @kind == :singleton ? "." : "#"
          @passed.each { |name| Analysis::DependencyRecorder.read_missing(:method, "#{name}#{separator}#{@method_name}") }
        end

        # For every other verdict — a firing, or an opaque owner level whose opacity another file's edit can
        # lift — the walk's reads are the dependency, so they are recorded as read.
        def settle_by_walk
          Analysis::DependencyRecorder.replay(@withheld) unless @withheld.nil?
        end

        # Stage 2, for the class {#owner_envelope} last answered.
        def authoritative?(class_name)
          !load_order_dependent?(class_name) && !object_extension_may_shadow? &&
            @levels.all? { |level| clean_level?(level) && public_at?(level.class_name) } &&
            chain_free_of_hooks?(class_name) &&
            subclasses_agree?(class_name, @envelope)
        end

        private

        def walk_to_owner(class_name)
          @levels = []
          @passed = []
          walked_whole_chain?(class_name) do |current|
            level = level_for(current)
            @levels << level
            found = level_envelopes(level)
            if found.empty?
              @passed.concat([current] + level.modules)
              next
            end

            envelope = found.first
            @owner_entries = owner_entries(level)
            unless found.all?(envelope) && !Source::ParameterEnvelope.opaque?(envelope)
              @ambiguous = true
              return nil
            end

            return @envelope = envelope
          end
          nil
        end

        def owner_entries(level)
          own = @scope.parameter_envelopes_of(level.class_name).key?([@kind, @method_name])
          entries = own ? [[level.class_name, @kind]] : []
          level.modules.each do |mod|
            entries << [mod, :instance] if @scope.parameter_envelopes_of(mod).key?([:instance, @method_name])
          end
          entries
        end

        # The survey corpus's own lesson. `PStore.new(path).transaction { … }` inside `module TDiary::IO`
        # resolves `PStore` to the project's `TDiary::IO::PStore` when that class's file is loaded, and to the
        # stdlib `::PStore` when it is not — and tdiary loads it only under one `io_class` setting, so under
        # the default one the call is correct code. The analysis universe holds every file at once, so it
        # always picks the inner class. Whenever the receiver's class is one of SEVERAL known classes the
        # call site's `Module.nesting` spells with the same last segment, which one the receiver is depends
        # on load order, and a verdict against the project class's `def` is not one the program backs.
        def load_order_dependent?(class_name)
          segment = class_name.to_s.split("::").last
          candidates = Rigor::Reflection.lexical_nesting_chain(@scope).map { |entry| "#{entry}::#{segment}" }
          candidates << segment
          known = candidates.uniq.select { |name| known_class?(name) }
          known.include?(class_name.to_s) && known.size > 1
        end

        # A module some method body hands to `obj.extend` sits ahead of the object's class, so if it defines
        # the name at all, that object answers with the module's definition.
        def object_extension_may_shadow?
          @scope.discovered_parameter_envelopes.any? do |_name, bucket|
            bucket.key?(Scope::DiscoveryIndex::ENVELOPE_OBJECT_EXTENDED_MARK) && bucket.key?([:instance, @method_name])
          end
        end

        def known_class?(name)
          @scope.discovered_classes.key?(name) || Rigor::Reflection.rbs_class_known?(name, scope: @scope)
        end

        # False when the walk stopped at the ADR-41 budget rather than at the top of the chain: budget
        # exhaustion is uncertainty, and every caller reads it as a reason to decline.
        def walked_whole_chain?(class_name)
          current = class_name.to_s
          seen = {}
          while current && !seen[current]
            return false if seen.size >= Scope::ANCESTOR_WALK_LIMIT

            seen[current] = true
            yield current
            current = resolve(current, @scope.superclass_of(current))
          end
          true
        end

        def level_for(class_name)
          modules = []
          externals = []
          collect_mixins(class_name, own_mixins(class_name), modules, externals, {})
          Level.new(class_name: class_name, modules: modules, externals: externals)
        end

        # Instance methods reach a receiver through `include` / `prepend`; class methods through `extend`, and
        # an extended module's own `include`s reach the same singleton.
        def own_mixins(class_name)
          @kind == :singleton ? (@scope.discovered_extends[class_name] || []) : @scope.includes_of(class_name)
        end

        # Issue #986 — a name the compact-header rename collision left ambiguous resolves to no ONE class,
        # but BOTH classes it names are ancestors at runtime; only their MRO order is unknowable. Taking
        # both as levels is what keeps this rule alive for the rest of the receiver: a method only one of
        # them declares still has one envelope and still fires, a method they disagree about lands two on
        # `#envelope_for`'s join and declines there, and the class's own `def`s, its superclass's and its
        # unambiguous mixins are untouched. Letting the decline arrive as an unknown EXTERNAL mixin instead
        # suppressed the rule for every level of the receiver.
        def collect_mixins(owner, raw_names, modules, externals, seen)
          raw_names.each do |raw|
            resolved = resolve(owner, raw)
            names = resolved ? [resolved] : @scope.ambiguous_ancestor_resolutions(owner, raw)
            next externals << @scope.ancestor_name_candidates(owner, raw) if names.empty?

            names.each do |name|
              next if seen[name]

              seen[name] = true
              modules << name
              collect_mixins(name, @scope.includes_of(name), modules, externals, seen)
            end
          end
        end

        def resolve(owner, raw)
          return nil if raw.nil?

          bucket = (@name_memo[owner] ||= {})
          return bucket[raw] if bucket.key?(raw)

          bucket[raw] = @scope.ancestor_name_candidates(owner, raw).find { |name| project_class?(name) }
        end

        def project_class?(name)
          @scope.known_user_class?(name) || @scope.discovered_parameter_envelopes.key?(name)
        end

        # A module's methods reach the receiver as instance methods whichever side the receiver is on.
        def level_envelopes(level)
          own = @scope.parameter_envelopes_of(level.class_name)[[@kind, @method_name]]
          mixed = level.modules.map { |mod| @scope.parameter_envelopes_of(mod)[[:instance, @method_name]] }
          ([own] + mixed).compact
        end

        def clean_level?(level)
          ([level.class_name] + level.modules).none? { |name| dynamic_surface?(name) || project_patched?(name) } &&
            level.externals.all? { |candidates| external_mixin_lacks_method?(candidates) }
        end

        def dynamic_surface?(class_name)
          Scope::DiscoveryIndex.rewritten_surface?(@scope.parameter_envelopes_of(class_name))
        end

        def project_patched?(class_name)
          environment = @scope.environment
          patched = environment&.project_patched_methods
          return true if patched && !patched.empty? && patch_names_method?(patched, class_name)

          synthetic = environment&.synthetic_method_index
          return false if synthetic.nil? || synthetic.empty?

          synthetic.knows_class?(class_name) || !synthetic.lookup_instance(class_name, @method_name).empty? ||
            !synthetic.lookup_singleton(class_name, @method_name).empty?
        end

        def patch_names_method?(patched, class_name)
          %i[instance singleton].any? do |kind|
            !patched.lookup(class_name: class_name, method_name: @method_name, kind: kind).nil?
          end
        end

        # A mixin the project does not declare may define the name with any arity, and `prepend` lets it win
        # over the class's own `def`. Only a module RBS knows, and whose declaration lacks the name, is
        # evidence that it does not.
        def external_mixin_lacks_method?(candidates)
          name = candidates.find { |candidate| Rigor::Reflection.rbs_class_known?(candidate, scope: @scope) }
          return false if name.nil?

          Rigor::Reflection.instance_method_definition(name, @method_name, scope: @scope).nil?
        rescue StandardError
          false
        end

        def public_at?(class_name)
          visibility = @scope.discovered_method_visibility(class_name, @method_name)
          visibility.nil? || visibility == :public
        end

        # A hook anywhere in the chain, including above the owner, and on either side: a class that answers
        # names it does not define is a class whose `def`s are not the whole story of what a call reaches.
        def chain_free_of_hooks?(class_name)
          walked_whole_chain?(class_name) do |current|
            ([current] + level_for(current).modules).each do |name|
              envelopes = @scope.parameter_envelopes_of(name)
              return false if dynamic_surface?(name)
              return false if MISSING_HOOKS.any? { |hook| hook_recorded?(envelopes, hook) }
            end
          end
        end

        def hook_recorded?(envelopes, hook)
          envelopes.key?([:instance, hook]) || envelopes.key?([:singleton, hook])
        end

        # Every project class whose superclass chain reaches the receiver's class: a value typed as the
        # receiver may be any of them, and each one's own definition of the name is what runs for it.
        def subclasses_agree?(class_name, envelope)
          each_subclass(class_name) do |subclass|
            level = level_for(subclass)
            return false unless clean_level?(level)
            return false unless level_envelopes(level).all?(envelope)
          end
          true
        end

        def each_subclass(class_name)
          children = children_by_parent
          queue = children.fetch(class_name.to_s, []).dup
          seen = {}
          until queue.empty?
            subclass = queue.shift
            next if seen[subclass]

            seen[subclass] = true
            yield subclass
            queue.concat(children.fetch(subclass, []))
          end
        end

        def children_by_parent
          @scope.discovered_superclasses.each_with_object({}) do |(child, raw_parent), children|
            parent = resolve(child, raw_parent)
            (children[parent] ||= []) << child if parent
          end
        end
      end
    end
  end
end
