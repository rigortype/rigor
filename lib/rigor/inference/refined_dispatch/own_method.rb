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
      module OwnMethod
        # One candidate definer as `DefinerResolution`'s per-chain answer function reports it, read through the
        # same four readers as the module's own hit (a call site may not name that one).
        DefinerHit = Data.define(:answer, :owner, :index, :side)
        EMPTY = [].freeze
        private_constant :DefinerHit, :EMPTY

        module_function

        # Is `method_name` on an instance of `class_name` answered by the receiver's own method, ahead of every
        # refinement the in-effect list `list` (no unknown marker, no opaque module) puts in effect?
        def answers?(scope, class_name, method_name, list)
          InEffectRefinements.record_refinement_names(method_name)
          raw = raw_targets(scope.discovered_refinements, method_name, list)
          return true if raw.nil?

          record_targets(scope, raw)
          return false if raw.each_key.any? { |refined| InEffectRefinements.class_wildcard_key?(scope, refined) }

          levels = RefinedDispatch.levels(scope, class_name)
          return false if levels.nil?
          return false if refined_off_levels?(scope, class_name, levels, raw)

          shadowing_definer?(scope, class_name, levels, method_name, raw)
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
        # definer.
        def refined_off_levels?(scope, class_name, levels, raw)
          return true if unplaced_target?(scope, raw) || subclass_refined?(scope, class_name, raw)

          on_levels = level_names(levels)
          raw.each_key.any? do |refined|
            next false if on_levels.include?(refined)

            module_name?(scope, refined) || rbs_subclass?(scope, refined, class_name)
          end
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
        def subclass_refined?(scope, class_name, raw)
          each_subclass(scope, class_name) do |subclass|
            chain = Scope::ResolutionChain.for(scope, subclass, :instance, :methods)
            chain.record(scope) if Analysis::DependencyRecorder.active?
            return true if chain.truncated? || chain.wildcard_mixin? || chain.level_count.zero?
            return true if chain.level_entries(0).any? { |entry| refined_entry?(entry, raw) }
          end
          false
        end

        def refined_entry?(entry, raw)
          return entry.candidates.any? { |candidate| raw.include?(candidate) } if entry.external?

          raw.include?(entry.name)
        end

        def each_subclass(scope, class_name)
          children = children_by_parent(scope)
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
        def shadowing_definer?(scope, class_name, levels, method_name, raw)
          levels.each do |level_class, entries, mixed, every|
            return false if mixed || (level_class && raw.include?(level_class))

            (every || entries).each do |entry|
              case entry_answer(scope, entry, level_class, method_name, raw)
              when :refined then return false
              when :defines then return proven_definer?(scope, class_name, entry, method_name)
              end
            end
          end
          false
        end

        # `:refined`, `:defines`, or nil to move on. The level's own class was asked before its entries.
        def entry_answer(scope, entry, level_class, method_name, raw)
          return entry.any? { |candidate| raw.include?(candidate) } ? :refined : nil if entry.is_a?(Array)
          return :refined if entry != level_class && raw.include?(entry)

          :defines if RefinedDispatch.defines?(scope, entry, method_name)
        end

        # Is Ruby known to find `method_name` on `entry`, the first definer the walk reached for an instance of
        # `class_name`? Neither proof stands on a class that rewrites its method table in a way no literal names
        # (`ENVELOPE_DYNAMIC_MARK`).
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
        def proven_definer?(scope, class_name, entry, method_name)
          Analysis::DependencyRecorder.read_last_segment(:class, entry) if Analysis::DependencyRecorder.active?
          bucket = scope.parameter_envelopes_of(entry)
          return false if bucket.key?(Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)

          opaque = Source::ParameterEnvelope.opaque?(bucket[[:instance, method_name.to_sym]])
          return true if project_definer?(scope, class_name, entry, method_name, opaque)

          !opaque && Builtins::CRubyDefiners.defines?(entry, method_name)
        end

        # A `def` counts while its envelope is its own; an `attr_*` or `define_method` always records an opaque one,
        # so for those the existence table and the certainty read are the whole proof.
        def project_definer?(scope, class_name, entry, method_name, opaque)
          if scope.user_def_for(entry, method_name)
            return false if opaque
          elsif !scope.discovered_method?(entry, method_name, :instance)
            return false
          end

          certain_owner?(scope, class_name, entry, method_name)
        end

        # ADR-119 WD2 — the candidate-set read over the receiver's chain, with every project `def`, `attr_*` and
        # `define_method` as a candidate: true only for a `Known` answer whose owner is `entry`.
        def certain_owner?(scope, class_name, entry, method_name)
          case DefinerResolution.resolve(scope, class_name, method_name, :instance, question: :definer,
                                         &definer_answer(scope, method_name))
          in DefinerResolution::Known(answer: _answer, owner:) then owner == entry
          in DefinerResolution::UNKNOWN then false
          in DefinerResolution::ABSENT then false # rubocop:disable Lint/DuplicateBranch
          end
        end

        # The first project entry at or after `from` that defines `method_name` on its instance side, by a `def` or
        # by another definer the existence table records (`attr_*`, `define_method`).
        def definer_answer(scope, method_name)
          lambda do |chain, from|
            index = from - 1
            chain.search(scope, from) do |entry|
              index += 1
              next if entry.external? || entry.side != :instance
              next unless scope.user_def_for(entry.name, method_name) ||
                          scope.discovered_method?(entry.name, method_name, :instance)

              DefinerHit.new(entry.name, entry.name, index, entry.side)
            end
          end
        end
      end
    end
  end
end
