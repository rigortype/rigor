# frozen_string_literal: true

require_relative "../builtins/cruby_definers"

module Rigor
  module Inference
    module RefinedDispatch
      # Issue #1740 — does the receiver's own lookup answer a call ahead of every refinement in effect, so that
      # `call.wrong-arity` and `call.argument-type-mismatch` may check it against the receiver's own method? Ruby
      # finds a method the receiver's class (or a nearer ancestor) defines before it consults an ancestor's
      # refinement: under `refine Object do def center(a, b, c)`, `"x".center(1, 2, 3)` still runs `String#center`
      # and raises.
      #
      # It answers yes only from positive knowledge (the caller has already declined on an in-effect list that
      # carries {InEffectRefinements::UNKNOWN} or an opaque module), and every condition it cannot prove is a no:
      #
      # - it reads the RAW refinement table, every name a `refine` argument's spelling can denote and the wildcard
      #   rows included, never {RefinedDispatch.resolved}'s typing subset: a decline needs only that a row may
      #   denote a class on the walk;
      # - no in-effect row may name a class the walk cannot name, a project subclass of the receiver's class (a
      #   value typed as the class may be one), or a module the receiver's levels do not hold (`obj.extend(M)`,
      #   or a subclass's mixin);
      # - walking {RefinedDispatch.levels} from the most derived, the first level or entry that is refined or
      #   defines the name must define it, with no `mixed` level (a project mixin RBS does not place) before it;
      # - that definer must be proven ({.proven_definer?}): RBS alone is not proof.
      #
      # It shares the level walk with the typed arm's {RefinedDispatch.winner} and nothing else: the typer types
      # only from rows the lexical lookup resolves, while a decline must count every row.
      #
      # Issue #1752 — `kind: :singleton` asks the same of a class object, over its singleton levels
      # ({ClassObject}): `Integer.sqrt` (CRuby's own singleton method of `Integer`) answers ahead of a refinement of
      # `Object#sqrt`, while a refinement of a module the class extends answers ahead of the class's methods
      # further up. A singleton class's definer is proven by its own `def self.x` / `class << self` definer
      # (`DefinerResolution` `Known` on the singleton side) or by the catalogue's singleton methods.
      module OwnMethod # rubocop:disable Metrics/ModuleLength
        # One candidate definer as `DefinerResolution`'s per-chain answer function reports it, read through the
        # same four readers as the module's own hit (a call site may not name that one).
        DefinerHit = Data.define(:answer, :owner, :index, :side)
        EMPTY = [].freeze
        private_constant :DefinerHit, :EMPTY

        module_function

        # Is `method_name` on an instance of `class_name` (on the class object itself for `kind: :singleton`)
        # answered by the receiver's own method, ahead of every refinement the in-effect list `list` (no unknown
        # marker, no opaque module) puts in effect?
        def answers?(scope, class_name, method_name, list, kind: :instance)
          InEffectRefinements.record_refinement_names(method_name)
          raw = raw_targets(scope.discovered_refinements, method_name, list)
          return true if raw.nil?

          add_ancestor_spellings(scope, raw)

          record_targets(scope, raw)
          return false if raw.each_key.any? { |refined| InEffectRefinements.class_wildcard_key?(scope, refined) }

          levels = RefinedDispatch.levels(scope, class_name, kind: kind)
          return false if levels.nil?
          return false if refined_off_levels?(scope, [class_name, kind], levels, raw)

          shadowing_definer?(scope, [class_name, kind], levels, method_name, raw)
        end

        # `{refined-class key => [its in-effect refining modules]}` for every key with a row for `method_name` or a
        # names-wildcard row that `list` puts in effect, by every spelling the table records, or nil when there is
        # none.
        def raw_targets(refinements, method_name, list)
          out = nil
          refinements.each do |refined, methods|
            modules = in_effect_modules(methods[method_name], list) |
                      in_effect_modules(methods[RefinedDispatch.wildcard], list)
            (out ||= {})[refined] = modules unless modules.empty?
          end
          out
        end

        # Ruby looks a constant up through the refining module's ancestors before the top level, so `refine(Bar)` in
        # a module that includes `Foo` refines `Foo::Bar` when `Foo` holds one; the table records the lexical
        # spellings only (`R::Bar`, `Bar`). Each declared `<ancestor>::<last segment>` joins the raw targets for the
        # same refining module: over-adding only declines.
        def add_ancestor_spellings(scope, raw)
          raw.to_a.each do |refined, modules|
            segment = refined.split("::").last
            modules.each do |module_name|
              ancestor_modules(scope, module_name).each do |ancestor|
                spelling = "#{ancestor}::#{segment}"
                next unless declared_class?(scope, spelling)

                raw[spelling] = (raw[spelling] || EMPTY) | [module_name]
              end
            end
          end
        end

        # The modules `module_name` includes or prepends, transitively (`InEffectRefinements.activated_modules`, which
        # records the chain's edges), itself left out.
        def ancestor_modules(scope, module_name)
          return EMPTY if module_name == RefinedDispatch.wildcard

          ancestors = InEffectRefinements.activated_modules(scope, module_name)
          ancestors.is_a?(Array) ? ancestors - [module_name] : EMPTY
        end

        def in_effect_modules(rows, list)
          return EMPTY if rows.nil?

          rows.select { |name| RefinedDispatch.in_effect?([name], list) }
        end

        # ADR-46 — a refined class appearing or vanishing (a new subclass declaration, a module turning up where a
        # spelling named nothing), or an edit to a file declaring one (`class Kid` becoming `class Kid < Base`),
        # moves the answer.
        def record_targets(scope, raw)
          return unless Analysis::DependencyRecorder.active?

          raw.each_key do |refined|
            next if refined == RefinedDispatch.wildcard

            Analysis::DependencyRecorder.read_last_segment(:class, refined)
            Scope::ResolutionChain.record_class(scope, refined)
          end
        end

        # A refined class the receiver's levels do not show, but which a value typed as the receiver's class may
        # still reach (critique F4): a project subclass of the class, or one whose own level mixes in a refined
        # module (a module already on the class's levels is prepended again by `prepend`); a class RBS declares as
        # a subclass; a module not on the levels, which `obj.extend` or a subclass's mixin can put ahead of the
        # definer; and a module on the levels that some code prepends to an object's singleton class.
        #
        # Issue #1752 — for a class object (`receiver` `[class_name, :singleton]`) a value typed as the class object
        # may be a subclass's, whose singleton level may extend a refined module; and a class is off its lookup when it
        # is placed away from `Module`, of which every class object is an instance.
        def refined_off_levels?(scope, (class_name, kind), levels, raw)
          return true if unplaced_target?(scope, raw) || subclass_refined?(scope, class_name, raw, kind)

          placed_from = kind == :singleton ? "Module" : class_name
          on_levels = level_names(levels)
          raw.each_key.any? do |refined|
            next object_prepended?(scope, refined) if on_levels.include?(refined)
            next true if module_name?(scope, refined)

            declared_class?(scope, refined) && !placed_away?(scope, refined, placed_from)
          end
        end

        # Issue #1820 — can the class `key`, off the receiver's levels, be proven never to sit at or below
        # `class_name` in an object's ancestry? Only when RBS does not declare it a subclass and its whole instance
        # chain is read: no cut, no mixin the tables cannot name, no superclass the tables do not know (`class K <
        # <expr>`, `K = Class.new(Parent)`, a superclass RBS does not declare), and `class_name` nowhere on it.
        def placed_away?(scope, key, class_name)
          return false if rbs_subclass?(scope, key, class_name)
          return rbs_away?(scope, key, class_name) unless project_class?(scope, key)

          chain = Scope::ResolutionChain.for(scope, key, :instance, :methods)
          chain.record(scope) if Analysis::DependencyRecorder.active?
          return false if chain.truncated? || chain.wildcard_mixin?

          chain.level_count.times.all? { |index| level_away?(scope, chain, index, class_name) }
        end

        # A project level is away when it is not `class_name` and its superclass is known; an external superclass
        # level when RBS declares it and its RBS ancestors do not hold `class_name`.
        def level_away?(scope, chain, index, class_name)
          level_class = chain.level_classes[index]
          return level_class != class_name && !unknown_superclass?(scope, level_class) if level_class

          external = chain.level_entries(index).find(&:external?)
          name = external&.candidates&.find { |candidate| scope.environment&.class_known?(candidate) }
          !name.nil? && rbs_away?(scope, name, class_name)
        end

        def rbs_away?(scope, name, class_name)
          loader = scope.environment&.rbs_loader
          ancestors = loader ? loader.ancestor_names_for(name) : EMPTY
          !ancestors.empty? && !ancestors.include?(class_name)
        end

        def project_class?(scope, name)
          scope.discovered_classes.key?(name) || !(scope.discovered_class_sources[name] || EMPTY).empty? ||
            scope.known_user_class?(name)
        end

        # A project class whose superclass the tables do not know: `class K < <expr>` (the superclass table records
        # `nil`) or `K = Class.new(Parent)` (`ENVELOPE_META_SUPERCLASS_MARK`).
        def unknown_superclass?(scope, name)
          superclasses = scope.discovered_superclasses
          return true if superclasses.key?(name) && superclasses[name].nil?

          scope.discovered_parameter_envelopes[name]&.key?(Scope::DiscoveryIndex::ENVELOPE_META_SUPERCLASS_MARK) ||
            false
        end

        # A module some code `prepend`s to an object's singleton class (or `extend`s an object with in a method
        # body), which puts it ahead of the object's class even where the class already includes it.
        def object_prepended?(scope, name)
          scope.discovered_parameter_envelopes[name]&.key?(Scope::DiscoveryIndex::ENVELOPE_OBJECT_EXTENDED_MARK) ||
            false
        end

        # Is some in-effect row under a class no table declares by any spelling of it (the keys sharing its last
        # segment that the same refining module refines)? Ruby resolved that `refine` argument to some class, through
        # a lookup the table did not follow (the refining module's own ancestors: `module R; include Foo;
        # refine(Bar)` refines `Foo::Bar`) or to a class outside the analysed paths (a vendored `VendorStr <
        # String`), and Rigor cannot place it in the receiver's hierarchy.
        def unplaced_target?(scope, raw)
          raw.any? do |refined, modules|
            segment = refined.split("::").last
            modules.any? do |module_name|
              raw.none? do |other, others|
                others.include?(module_name) && other.split("::").last == segment && declared_class?(scope, other)
              end
            end
          end
        end

        def declared_class?(scope, name)
          scope.discovered_classes.key?(name) || !(scope.discovered_class_sources[name] || EMPTY).empty? ||
            scope.known_user_class?(name) || scope.environment&.class_known?(name) || false
        end

        def level_names(levels)
          names = Set.new
          levels.each do |level_class, entries, _mixed, every|
            names << level_class if level_class
            (every || entries).each { |entry| entry.is_a?(Array) ? names.merge(entry) : names << entry }
          end
          names
        end

        def module_name?(scope, name)
          bucket = scope.discovered_parameter_envelopes[name]
          return true if bucket&.key?(Scope::DiscoveryIndex::ENVELOPE_MODULE_MARK)

          scope.environment&.rbs_module?(name) || false
        end

        def rbs_subclass?(scope, refined, class_name)
          environment = scope.environment
          !environment.nil? && environment.class_known?(refined) &&
            environment.class_ordering(refined, class_name) == :subclass
        end

        # Does a project subclass of `class_name` (the `discovered_superclasses` walk `SourceArity` makes, its
        # parents resolved to any class the project or RBS knows, so a subclass of a core class counts) carry a
        # refined entry on its own level, or a level the walk cannot read?
        #
        # A subclass level the walk cannot read (a truncated chain, or a mixin the tables cannot name) hides only
        # modules, so it declines only when some in-effect row names a module. `kind` `:singleton` reads each
        # subclass's singleton level, whose own singleton class no refinement table key names.
        def subclass_refined?(scope, class_name, raw, kind = :instance)
          each_subclass(scope, class_name) do |subclass|
            chain = Scope::ResolutionChain.for(scope, subclass, kind, :methods)
            chain.record(scope) if Analysis::DependencyRecorder.active?
            if chain.truncated? || chain.wildcard_mixin? || chain.level_count.zero?
              return true if raw.each_key.any? { |refined| module_name?(scope, refined) }

              next
            end
            return true if chain.level_entries(0).any? { |entry| refined_entry?(entry, raw) }
          end
          false
        end

        def refined_entry?(entry, raw)
          return entry.candidates.any? { |candidate| raw.include?(candidate) } if entry.external?
          return false if entry.side == :singleton

          raw.include?(entry.name)
        end

        # ADR-46 — every class whose subclasses are enumerated records `subclass_of:<last segment>`, which a class
        # declaration with that superclass appearing or vanishing fires (`IncrementalSession#negative_affected`).
        # A class whose superclass the tables do not know may be a subclass of any class, so it joins the walk too
        # (`subclass_of:*`, which any class declaration appearing or vanishing fires).
        def each_subclass(scope, class_name)
          children = children_by_parent(scope)
          record_subclasses_read(class_name)
          queue = children.fetch(class_name.to_s, []) + unknown_superclass_classes(scope, class_name)
          seen = {}
          until queue.empty?
            subclass = queue.shift
            next if seen[subclass]

            seen[subclass] = true
            record_subclasses_read(subclass)
            yield subclass
            queue.concat(children.fetch(subclass, []))
          end
        end

        def unknown_superclass_classes(scope, class_name)
          Analysis::DependencyRecorder.read_name(:subclass_of, "*") if Analysis::DependencyRecorder.active?
          mark = Scope::DiscoveryIndex::ENVELOPE_META_SUPERCLASS_MARK
          computed = scope.discovered_superclasses.filter_map { |child, parent| child if parent.nil? }
          meta = scope.discovered_parameter_envelopes.filter_map { |name, bucket| name if bucket.key?(mark) }
          (computed + meta).uniq - [class_name.to_s]
        end

        def record_subclasses_read(class_name)
          return unless Analysis::DependencyRecorder.active?

          Analysis::DependencyRecorder.read_last_segment(:subclass_of, class_name.to_s)
        end

        def children_by_parent(scope)
          scope.discovered_superclasses.each_with_object({}) do |(child, raw_parent), children|
            parent = scope.ancestor_name_candidates(child, raw_parent).find { |name| known_class?(scope, name) }
            (children[parent] ||= []) << child if parent
          end
        end

        def known_class?(scope, name)
          scope.known_user_class?(name) || scope.discovered_parameter_envelopes.key?(name) ||
            scope.environment&.class_known?(name) || false
        end

        # Walks the levels from the most derived: true when the first level or entry that a raw target names or
        # that defines `method_name` defines it, and that definer is proven. A refined level or entry (an entry no
        # table names by any of its candidate names), a `mixed` level (a project mixin RBS does not place, which
        # may be prepended or refined), an unproven definer, and the end of the walk all answer false. An entry no
        # table names is passed over otherwise: it cannot be proven a definer, and a definer the walk misses there
        # sits ahead of every refinement the walk then reaches.
        #
        # Issue #1752 — a singleton level with a refined module answers false whatever its order: the tables record
        # `class << self; prepend M` as an `extend`, so the module may sit ahead of the class's own singleton methods.
        def shadowing_definer?(scope, receiver, levels, method_name, raw)
          levels.each do |level_class, entries, mixed, every|
            return false if mixed || (level_class && raw.include?(level_class))

            row = every || entries
            return false if level_class.is_a?(SingletonClass) && singleton_level_refined?(row, raw)

            row.each do |entry|
              case entry_answer(scope, entry, level_class, method_name, raw)
              when :refined then return false
              when :defines then return proven_definer?(scope, receiver, entry, method_name)
              end
            end
          end
          false
        end

        def singleton_level_refined?(row, raw)
          row.any? do |entry|
            next entry.any? { |candidate| raw.include?(candidate) } if entry.is_a?(Array)

            !entry.is_a?(SingletonClass) && raw.include?(entry)
          end
        end

        # `:refined`, `:defines`, or nil to move on. The level's own class was asked before its entries.
        def entry_answer(scope, entry, level_class, method_name, raw)
          return entry.any? { |candidate| raw.include?(candidate) } ? :refined : nil if entry.is_a?(Array)
          return :refined if entry != level_class && raw.include?(entry)

          :defines if RefinedDispatch.defines?(scope, entry, method_name)
        end

        # Is Ruby known to find `method_name` on `entry`, the first definer the walk reached for an instance of
        # `class_name`? Neither proof stands on a class that rewrites its method table in a way no literal names
        # (`ENVELOPE_DYNAMIC_MARK`), nor for a name the project removes from it with a literal `undef`,
        # `remove_method` or `undef_method` anywhere (`ENVELOPE_REMOVED_KIND`), whatever defined it.
        #
        # - A project `def`, `attr_*` or `define_method` (ADR-119 A7): `DefinerResolution` must answer `Known` with
        #   `entry` as the owner, on the receiver's chain, so a definer that may not have run (a `def` under `if`,
        #   which Ruby skips, leaving the ancestor's refinement to answer) or that an unplaced mixin or fork may
        #   precede is not proof. A `def` whose envelope something made opaque (`remove_method`, `undef`, an
        #   alias, a wrapping macro) is not proof either.
        # - A core method the offline CRuby catalogue lists on `entry` itself ({Builtins::CRubyDefiners}), which the
        #   project has not removed or rewritten there (A9: no opaque envelope for the name, which `remove_method`
        #   and `undef` record). Core RBS is not proof: it redeclares some inherited methods on a subclass
        #   (`Integer#quo`, `File#to_path`, owned by `Numeric` and `IO`) and declares some CRuby no longer defines
        #   (`Process::Status#&`).
        #
        # ADR-46 — the envelope bucket records the files declaring `entry`, and the class edge a new file reopening
        # it (to `remove_method` the name, say) fires.
        #
        # Issue #1752 — a {SingletonClass} entry is proven on its class's singleton side: its own singleton definer,
        # `Known` on the class object's chain, or the catalogue's singleton methods. Any other entry of a class
        # object's walk (an extended module; `Class`, `Module`, `Object`, `Kernel`) is proven as an instance-side
        # entry is, with the certainty read over the class object's chain.
        def proven_definer?(scope, receiver, entry, method_name)
          owner, side = entry.is_a?(SingletonClass) ? [entry.of, :singleton] : [entry, :instance]
          Analysis::DependencyRecorder.read_last_segment(:class, owner) if Analysis::DependencyRecorder.active?
          bucket = scope.parameter_envelopes_of(owner)
          return false if bucket.key?(Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)
          return false if bucket.key?([Scope::DiscoveryIndex::ENVELOPE_REMOVED_KIND, method_name.to_sym])

          opaque = Source::ParameterEnvelope.opaque?(bucket[[side, method_name.to_sym]])
          return true if project_definer?(scope, receiver, [owner, side], method_name, opaque)
          return false if opaque

          if side == :singleton
            Builtins::CRubyDefiners.singleton_defines?(owner, method_name)
          else
            Builtins::CRubyDefiners.defines?(owner, method_name)
          end
        end

        # A `def` counts while its envelope is its own (an alias or a wrapping macro makes it opaque); an `attr_*` or
        # `define_method` always records an opaque one, so for those the existence table and the certainty read are
        # the proof, beside the removal check above. A singleton name the extends fold copied from an extended module
        # is that module's (`ClassObject.own_singleton_definer?`).
        def project_definer?(scope, receiver, (owner, side), method_name, opaque)
          own = side == :singleton ? own_singleton_kind(scope, owner, method_name) : own_kind(scope, owner, method_name)
          return false if own.nil? || (own == :def && opaque)

          certain_owner?(scope, receiver, owner, method_name)
        end

        # `:def` for a `def` of the owner's own, `:other` for another definer the existence table records, or nil.
        def own_kind(scope, owner, method_name)
          return :def if scope.user_def_for(owner, method_name)

          :other if scope.discovered_method?(owner, method_name, :instance)
        end

        def own_singleton_kind(scope, owner, method_name)
          node = scope.singleton_def_for(owner, method_name)
          return :def if node && !ClassObject.fold_copy?(scope, owner, method_name)

          :other if ClassObject.own_singleton_definer?(scope, owner, method_name)
        end

        # ADR-119 WD2 — the candidate-set read over the receiver's chain (the class object's for `kind` `:singleton`),
        # with every project `def`, `attr_*` and `define_method` as a candidate: true only for a `Known` answer whose
        # owner is `owner`.
        def certain_owner?(scope, (class_name, kind), owner, method_name)
          case DefinerResolution.resolve(scope, class_name, method_name, kind, question: :definer,
                                         &definer_answer(scope, method_name))
          in DefinerResolution::Known(answer: _answer, owner: found) then found == owner
          in DefinerResolution::UNKNOWN then false
          in DefinerResolution::ABSENT then false # rubocop:disable Lint/DuplicateBranch
          end
        end

        # The first project entry at or after `from` that defines `method_name` on its side, by a `def` or by another
        # definer the existence table records (`attr_*`, `define_method`; `define_singleton_method` or an `attr_*` in
        # `class << self` on a singleton entry). A singleton name the extends fold copied is asked past by
        # `DefinerResolution` itself, so the module that wrote it answers at its own position.
        def definer_answer(scope, method_name)
          lambda do |chain, from|
            index = from - 1
            chain.search(scope, from) do |entry|
              index += 1
              next if entry.external? || !entry_defines?(scope, entry, method_name)

              DefinerHit.new(entry.name, entry.name, index, entry.side)
            end
          end
        end

        def entry_defines?(scope, entry, method_name)
          name = entry.name
          if entry.side == :singleton
            scope.singleton_def_for(name, method_name) || scope.discovered_method?(name, method_name, :singleton)
          else
            scope.user_def_for(name, method_name) || scope.discovered_method?(name, method_name, :instance)
          end
        end
      end
    end
  end
end
