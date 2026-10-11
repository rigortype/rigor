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
      # - no in-effect row may name a class the walk cannot name;
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
        private_constant :DefinerHit

        module_function

        # Is `method_name` on an instance of `class_name` answered by the receiver's own method, ahead of every
        # refinement the in-effect list `list` (no unknown marker, no opaque module) puts in effect?
        def answers?(scope, class_name, method_name, list)
          InEffectRefinements.record_refinement_names(method_name)
          raw = raw_targets(scope.discovered_refinements, method_name, list)
          return true if raw.nil?

          record_targets(raw)
          return false if raw.any? { |refined| InEffectRefinements.class_wildcard_key?(scope, refined) }

          levels = RefinedDispatch.levels(scope, class_name)
          return false if levels.nil?

          shadowing_definer?(scope, class_name, levels, method_name, raw)
        end

        # Every refined-class key with a row for `method_name` or a names-wildcard row whose refining modules `list`
        # puts in effect, by every spelling the table records, or nil when there is none.
        def raw_targets(refinements, method_name, list)
          out = nil
          refinements.each do |refined, methods|
            rows = methods[method_name]
            unread = methods[RefinedDispatch.wildcard]
            next unless (rows && RefinedDispatch.in_effect?(rows, list)) ||
                        (unread && RefinedDispatch.in_effect?(unread, list))

            (out ||= Set.new) << refined
          end
          out
        end

        # ADR-46 — a refined class appearing or vanishing (a module turning up where a spelling named nothing)
        # moves the answer.
        def record_targets(raw)
          return unless Analysis::DependencyRecorder.active?

          raw.each do |refined|
            Analysis::DependencyRecorder.read_last_segment(:class, refined) unless refined == RefinedDispatch.wildcard
          end
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
