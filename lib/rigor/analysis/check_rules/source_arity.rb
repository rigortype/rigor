# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../../inference/definer_resolution"
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
      #    whose project mixins, records the name. Every record at that level must agree — deliberately wider
      #    than Ruby's order, so a mixin whose definition may shadow the class's own, or a load-order-dependent
      #    pair (#986), declines instead of answering — and none may be opaque. A call that fits this envelope
      #    is silent, and nothing below is consulted.
      # 2. {#authoritative?} runs only for a call that would fire. It declines when a `method_missing` /
      #    `respond_to_missing?` hook or a dynamic-surface mark sits anywhere in the chain; when a mixin the
      #    project does not declare is not a known RBS module that lacks the name; when a `pre_eval:` patch or
      #    a plugin's synthetic method names it; when the owner does not make the method public; and when any
      #    project subclass of the receiver — whose instances the receiver's type admits — records a different
      #    or opaque envelope for it.
      #
      # ADR-119 C1b — on the instance side stage 1 and the subclass check ask `Inference::DefinerResolution`, and a
      # chain it declines (`UNKNOWN`) answers no envelope: where Ruby's order depends on a fact the tables cannot
      # prove, the rule is silent instead of checking the call against master's order (#1570).
      #
      # Deliberately NOT in scope: a constructor reached through `Class#new` (nothing records `initialize` as
      # `[:singleton, :new]`, so `.new` finds no owner unless the class writes `def self.new` itself); keyword
      # arity (the envelope's required-keyword flag declines, as `compute_arity_envelope` declines an RBS
      # function with required keywords); and a `class_eval` whose receiver is not a constant, which the
      # discovery walk cannot name.
      class SourceArity # rubocop:disable Metrics/ClassLength
        MISSING_HOOKS = %i[method_missing respond_to_missing?].freeze
        private_constant :MISSING_HOOKS

        # One class on the walk: its own name, the project modules its mixins resolve to (transitively through
        # their own `include`s), and the candidate-name lists of the mixins that resolve to no project module.
        #
        # Issue #1570 — the level is a SEGMENT of the receiver's `Scope::ResolutionChain` (`:arity` flavor): the
        # class with the modules Ruby inserts around it before the superclass's entries begin. Ruby skips an
        # `include` of a module the superclass chain already carries, so `class C < Base; include M` where
        # `Base` includes `M` leaves `M` at `Base`'s level; collecting every module a class's own `include`s
        # name put it at `C`'s level instead, where its `def` answered a call `Base#foo` receives.
        Level = Data.define(:class_name, :modules, :externals)
        private_constant :Level

        # ADR-119 C1b — the answer of a level whose records are not one non-opaque envelope. It equals itself in
        # every world, so two worlds that both reach such a level agree, and no envelope equals it.
        AMBIGUOUS = Object.new.freeze
        private_constant :AMBIGUOUS

        # What `Inference::DefinerResolution` reads off a candidate: the answer, the entry that gave it, its
        # position on the chain and its side. The same four readers as `DefinerResolution::Hit`, which a call site
        # may not name (the case/in contract spec allows no other reference to the module).
        ArityHit = Data.define(:answer, :owner, :index, :side)
        private_constant :ArityHit

        # A subclass level the walk cannot read: `subclasses_agree?` reads the nil as a decline.
        NO_LEVELS = [nil].freeze
        private_constant :NO_LEVELS

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
          @unknown = false
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
          # ADR-119 C1b — a declined chain (`@unknown`) is silent only until another file's edit lifts the
          # decline, so its verdict depends on everything the walk read, as an opaque level's does.
          return settle_by_walk if @unknown

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

        # ADR-119 C1b / #1570 — on the instance side the nearest level is asked of
        # {Inference::DefinerResolution}: the chain stands only where every candidate level gives one envelope
        # in every world Ruby may have run (a fork, an unproven mixin order, a `possible`-only definer). Where it
        # does not, the answer is NO envelope and `@unknown` — the rule stays silent — instead of master's
        # answer, which is what #1570 fired on. The levels the walk keeps for {#authoritative?} are the chain's.
        #
        # The SINGLETON side is untouched on purpose: the candidate-set read has no singleton side until
        # ADR-119 C1c designs it, so it keeps `Scope::ResolutionChain#settle` and the level walk the chain
        # replaced (`Scope::ResolutionChain::MasterOrder`) where the chain does not stand.
        def walk_to_owner(class_name)
          @levels = []
          @passed = []
          @master = false
          return walk_singleton_to_owner(class_name) if @kind == :singleton

          case Inference::DefinerResolution.resolve(@scope, class_name, @method_name, :instance,
                                                    question: :arity) { |chain, from| arity_hit(chain, from) }
          in Inference::DefinerResolution::Known(answer: _answer, owner: _owner) then nearest_envelope(class_name)
          in Inference::DefinerResolution::ABSENT then nearest_envelope(class_name) # rubocop:disable Lint/DuplicateBranch
          in Inference::DefinerResolution::UNKNOWN then decline
          end
        end

        # The chain's nearest level's envelope, filling the levels {#authoritative?} and {#settle_by_definitions}
        # read. Run only once the candidate-set read has answered, so the chain stands for the name.
        def nearest_envelope(class_name) = owner_in(chain_levels(arity_chain(class_name)).first)

        def decline
          @levels = []
          @passed = []
          @owner_entries = []
          @envelope = nil
          @unknown = true
          nil
        end

        # The first level at or after entry position `from` whose records name the method: its envelope (or
        # {AMBIGUOUS}), the entry that recorded it and that entry's position on the chain.
        def arity_hit(chain, from)
          start = 0
          chain.levels.each_with_index do |raw, index|
            level = Level.new(*raw)
            entries = chain.level_entries(index)
            first = start
            start += entries.size
            next if first < from

            found = level_envelopes(level)
            next if found.empty?

            envelope = found.first
            answer = found.all?(envelope) && !Source::ParameterEnvelope.opaque?(envelope) ? envelope : AMBIGUOUS
            owner = owner_entries(level).first.first
            position = first + (entries.index { |entry| entry.name == owner } || 0)
            return ArityHit.new(answer, owner, position, :instance)
          end
          nil
        end

        # The singleton side's walk, as it was before C1b: the chain's owner where `settle` lets it stand, and
        # master's where it does not. Both worlds' levels are kept for {#authoritative?}.
        def walk_singleton_to_owner(class_name)
          chain = arity_chain(class_name)
          envelope = owner_in(chain_levels(chain).first)
          # The retro read answers `false` (no envelope is `false`) unless it agrees with the chain's and neither
          # read was ambiguous (`@ambiguous` only ever turns true, so it covers both).
          verdict = chain.settle(@scope, envelope) do |retro|
            owner_in(chain_levels(retro).first) == envelope && !@ambiguous ? envelope : false
          end
          return envelope if verdict == :chain

          @levels = []
          @passed = []
          @owner_entries = []
          @ambiguous = false
          @master = true
          @envelope = nil
          owner_in(master_levels(class_name).first)
        end

        def owner_in(levels)
          levels.each do |level|
            @levels << level
            found = level_envelopes(level)
            if found.empty?
              @passed.concat([level.class_name] + level.modules)
              next
            end

            envelope = found.first
            @owner_entries |= owner_entries(level)
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

        # Yields each level of `class_name`'s walk — the chain's, or master's where {#walk_to_owner} fell back to
        # it. False when the walk stopped at the ADR-41 budget rather than ending: budget exhaustion is
        # uncertainty, and every caller reads it as a reason to decline.
        def walked_whole_chain?(class_name, &)
          levels, whole = @master ? master_levels(class_name) : chain_levels(arity_chain(class_name))
          levels.each(&)
          whole
        end

        # `[levels, whole]` for one world of the chain, up to the first superclass the project does not declare.
        def chain_levels(chain) = [chain.levels.map { |level| Level.new(*level) }, !chain.truncated?]

        def master_levels(class_name)
          levels, whole = Scope::ResolutionChain::MasterOrder.arity_levels(@scope, class_name.to_s, side)
          [levels.map { |level| Level.new(*level) }, whole]
        end

        def side = @kind == :singleton ? :singleton : :instance

        # Instance methods reach a receiver through `include` / `prepend`; class methods through `extend`, and
        # an extended module's own `include`s reach the same singleton — the chain's singleton side.
        #
        # Issue #986 — the `:arity` flavor expands a name the compact-header rename collision left ambiguous
        # to BOTH classes it names: both are ancestors at runtime and only their MRO order is unknowable. Taking
        # both into the level is what keeps this rule alive for the rest of the receiver: a method only one of
        # them declares still has one envelope and still fires, a method they disagree about lands two on the
        # level's join and declines there, and the class's own `def`s, its superclass's and its unambiguous
        # mixins are untouched. Letting the decline arrive as an unknown EXTERNAL mixin instead suppressed the
        # rule for every level of the receiver.
        def arity_chain(class_name) = Scope::ResolutionChain.for(@scope, class_name.to_s, side, :arity)

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
          walked_whole_chain?(class_name) do |level|
            ([level.class_name] + level.modules).each do |name|
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
            subclass_levels(subclass).each do |level|
              # A subclass whose own level the budget cut cannot be read, which is a reason to decline.
              return false if level.nil?
              return false unless clean_level?(level)
              return false unless level_envelopes(level).all?(envelope)
            end
          end
          true
        end

        # A subclass's own level (nil where the budget cut it or the chain does not stand for the name). The
        # instance side asks {Inference::DefinerResolution} (ADR-119 C1b): the subclass's own level answers, and a
        # fork, an unproven mixin order or a `possible`-only definer there is `UNKNOWN`, which
        # `subclasses_agree?` reads as a reason to decline. The singleton side keeps `settle` and master's walk,
        # as {#walk_singleton_to_owner} does.
        def subclass_levels(subclass)
          return singleton_subclass_levels(subclass) if @kind == :singleton

          case Inference::DefinerResolution.resolve(@scope, subclass, @method_name, :instance, question: :arity,
                                                    &own_level_answer(subclass))
          in Inference::DefinerResolution::Known(answer: _answer, owner: _owner) then [first_level(subclass)]
          in Inference::DefinerResolution::ABSENT then [nil]
          in Inference::DefinerResolution::UNKNOWN then NO_LEVELS
          end
        end

        # The subclass's own level, always a candidate (an empty answer where it records nothing), so that the
        # read asks whether the chain stands for the subclass and never whether an ancestor defines the name.
        def own_level_answer(subclass)
          lambda do |chain, from|
            next nil unless from.zero? && !chain.levels.empty?

            level = Level.new(*chain.levels.first)
            ArityHit.new(level_envelopes(level).uniq, subclass, 0, :instance)
          end
        end

        def first_level(class_name) = chain_levels(arity_chain(class_name)).first.first

        def singleton_subclass_levels(subclass)
          chain = arity_chain(subclass)
          own = chain_levels(chain).first.first
          verdict = chain.settle(@scope, own) { |retro| chain_levels(retro).first.first }
          [verdict == :chain ? own : master_levels(subclass).first.first]
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
