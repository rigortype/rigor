# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-119 WD2 — the candidate-set read over {Scope::ResolutionChain}, for a reader that can decline. It is
    # internal (not a `Scope` method, so the pinned public surface is unchanged) and answers one of three
    # things about a method name on a class:
    #
    # - {Known} — every candidate gives the same answer to the question asked;
    # - {UNKNOWN} — the chain does not stand for this name (a mark not discharged, a fork, a retro world that
    #   answers otherwise), a candidate disagrees, the walk was cut by the budget, an external ancestor ahead of
    #   the candidate may answer first (one RBS does not know, or knows and declares the name in; one it knows
    #   and whose declaration lacks the name is skipped);
    # - {ABSENT} — no project entry, no external entry and not the implicit `Object` can answer.
    #
    # On the singleton side (ADR-119 WD3, errata 2026-10-08) the chain is `K`'s singleton, its extends' instance
    # chains, then the superclass's singleton chain; an external superclass entry stands for its whole tail and is
    # tested against RBS's singleton side, an extended external module against its instance side, the implicit tail
    # after a project superclass against `Object`'s singleton side. A standing chain is then read past
    # {SingletonHookDecline}' positional decline: a hook's singleton-side edge is recorded on no includer, so the read
    # declines where one could have landed ahead of its last candidate.
    #
    # THE CALL SITE IS A CONTRACT. A result is consumed only by an exhaustive `case/in` that is the call's own
    # direct predicate, with one arm per answer and no `else` or `in _`, and is never stored, returned or
    # truth-tested: {UNKNOWN} and {ABSENT} are both truthy, so any other use folds a decline into a firing arm.
    # `spec/rigor/inference/definer_resolution_case_in_spec.rb` fails on a call site of any other shape.
    #
    # It migrates one question at a time: `SourceArity` (C1b) and the relationship lints (C1c) read the instance
    # side; no production reader reads the singleton side yet (C2-a landed it for C2's typing sites).
    module DefinerResolution
      Known = Data.define(:answer, :owner)
      UnknownResult = Data.define
      AbsentResult = Data.define
      UNKNOWN = UnknownResult.new
      ABSENT = AbsentResult.new

      # One candidate definer as a per-chain answer function reports it: the `answer` to the question, the
      # `owner` entry's name, the `index` of that entry on the chain and its `side` (`:instance` or `:singleton`).
      Hit = Data.define(:answer, :owner, :index, :side)

      QUESTIONS = %i[definer visibility arity override own_side].freeze
      NONE = :rigor_definer_resolution_none
      STRAY = :rigor_definer_resolution_stray
      private_constant :NONE, :STRAY

      module_function

      # `answer_in` is the question's per-chain answer function: called with a chain and a position, it returns
      # the {Hit} of the first project entry at or after the position that defines `method_name`, or nil. `:definer`
      # and `:visibility` have a default; every other question supplies its own. It is called once per candidate
      # on the chain, and again on the retro world when the chain has one fork, where `from` is mapped to the
      # entry it followed.
      def resolve(scope, class_name, method_name, side, question:, from: 0, &answer_in)
        raise ArgumentError, "unknown question #{question.inspect}" unless QUESTIONS.include?(question)

        answer_in = override_answer(scope, &answer_in) if question == :override
        answer_in ||= default_answer(scope, method_name, question)
        flavor = question == :arity ? :arity : :methods
        chain = Scope::ResolutionChain.for(scope, class_name.to_s, side, flavor)

        hits = candidates(scope, chain, method_name, from, answer_in)
        return UNKNOWN if hits.nil?

        own = own_hit?(scope, chain, method_name, hits)
        verdict = chain.settle(scope, outcomes(hits), owner: hits.first&.owner, unknown_for: method_name,
                                                      own_hit: own) do |retro|
          retro_from = retro_position(chain, retro, from)
          outcomes(retro_from && candidates(scope, retro, method_name, retro_from, answer_in))
        end
        return UNKNOWN unless verdict == :chain
        return UNKNOWN if side == :singleton && SingletonHookDecline.decline?(scope, chain, method_name, from, hits)

        collapse(hits)
      end

      # ADR-119 WD2 (#1622) — whether the candidate set is one certain definer that is the root's own instance
      # entry at the chain's head and records the name itself: what `settle`'s `own_hit:` says. The record test
      # matters where an answer function names the root without its recording the name (`SourceArity`'s
      # own-level answer is always a candidate, an empty one where the class records nothing).
      def own_hit?(scope, chain, method_name, hits)
        hit = hits.first
        return false unless hits.size == 1 && !hit.nil? && hit.index.zero? && hit.side == :instance
        return false unless hit.owner == chain.root

        scope.discovered_method?(hit.owner, method_name, :instance) || !scope.user_def_for(hit.owner, method_name).nil?
      end

      # The `:override` question's answer function, built from the caller's block: that block is NOT a per-chain
      # function but `|owner_name| value`, called on each project entry in order, and its first non-nil `value` is
      # the entry's answer, as `[owner_name, value]` (the owner is part of the answer so that two worlds naming
      # different parents disagree). It is the override lints' parent read: the nearest project ancestor after the
      # class whose block answers.
      def override_answer(scope)
        lambda do |chain, from|
          first_hit(chain, scope, from) do |entry|
            value = yield(entry.name)
            [entry.name, value] unless value.nil?
          end
        end
      end

      # `from` is a position on `chain`; the same position on the retro world is just after the entry it followed.
      # An entry the chain carries twice cannot be matched, which declines.
      def retro_position(chain, retro, from)
        return 0 if from.zero?

        entry = chain.entries[from - 1]
        return nil if entry.nil? || chain.entries.count(entry) > 1

        found = retro.entries.index(entry)
        found && (found + 1)
      end

      # The first definer and, while that definer is `possible`, the next; a nil joins the set when nothing
      # follows (the absent candidate). A cut chain, and a chain on which an external ancestor ahead of the
      # candidate (or, with no candidate, the implicit `Object`) may define the name, is a decline, answered by
      # nil instead of a set.
      def candidates(scope, chain, method_name, from, answer_in)
        hits = []
        position = from
        loop do
          hit = answer_in.call(chain, position)
          hit = past_fold_copies(scope, chain, method_name, hit, answer_in) if chain.side == :singleton
          return nil if hit.equal?(STRAY)

          raise ArgumentError, "answer function went backwards" if hit && hit.index < position
          return nil if hit.nil? && chain.truncated?

          hits << hit
          return decided(scope, chain, method_name, from, hits) if hit.nil? || !possible?(scope, hit, method_name)

          position = hit.index + 1
        end
      end

      # A class entry answering through a copy the extends fold made is asked past
      # (`SingletonHookDecline.copy_kind`), so the module that wrote the `def` answers at its own position; a copy
      # from a module the chain does not hold on that level is {STRAY}, a decline.
      def past_fold_copies(scope, chain, method_name, hit, answer_in)
        while hit
          case SingletonHookDecline.copy_kind(scope, chain, method_name, hit)
          when :copy then hit = answer_in.call(chain, hit.index + 1)
          when :stray then return STRAY
          else return hit
          end
        end
        hit
      end

      def decided(scope, chain, method_name, from, hits)
        external_may_answer?(scope, chain, method_name, from, hits.last) ? nil : hits
      end

      # An external entry ahead of the last candidate that RBS does not know, or knows and declares the name in,
      # may be the definer Ruby calls; with no candidate, so may the implicit `Object` (`Kernel`, for the object
      # that every class is). Both decline. Each tested external files the negative class edge on its spelling.
      def external_may_answer?(scope, chain, method_name, from, last)
        stop = last.nil? ? chain.entries.size : last.index
        recording = Analysis::DependencyRecorder.active?
        (from...stop).any? do |index|
          entry = chain.entries[index]
          next false unless entry.external?

          if recording
            Analysis::DependencyRecorder.read_missing(:class, entry.raw.to_s.split("::").last)
            Scope::ResolutionChain::Relevance.record_declared_module(scope, entry.candidates)
          end
          !external_lacks?(scope, entry.candidates, entry.side, method_name)
        end || (last.nil? && implicit_object_answers?(scope, chain, method_name))
      end

      # The implicit tail after a chain's last project superclass: `Object` (with `Kernel` and `BasicObject`) on the
      # instance side, `#<Class:Object>` through `Class`, `Module` and `Kernel` on the singleton side.
      def implicit_object_answers?(scope, chain, method_name)
        !external_lacks?(scope, ["Object"], chain.side, method_name)
      end

      # True only for an ancestor RBS knows whose declaration lacks the name, on the side the entry stands for: an
      # external superclass on a singleton chain (`:singleton`, its whole tail) is asked for a singleton method, an
      # extended module (`:instance`) and every instance-side entry for an instance method.
      def external_lacks?(scope, candidates, side, method_name)
        return Scope::ResolutionChain::Relevance.external_lacks?(scope, candidates, method_name) if side == :instance

        known = candidates.find { |candidate| Rigor::Reflection.rbs_class_known?(candidate, scope: scope) }
        return false if known.nil?

        Rigor::Reflection.singleton_method_definition(known, method_name, scope: scope).nil?
      rescue StandardError
        false
      end

      # What a candidate set says, for {Scope::ResolutionChain#settle} to compare across worlds.
      def outcomes(hits)
        return NONE if hits.nil?

        hits.map { |hit| hit.nil? ? NONE : hit.answer }
      end

      def collapse(hits)
        first = hits.first
        return ABSENT if hits.all?(&:nil?)
        return UNKNOWN if hits.any?(&:nil?) || hits.any? { |hit| hit.answer != first.answer }

        Known.new(first.answer, first.owner)
      end

      # A definer that rests on a fact the walk could not prove executes: the member's `possible` sibling, or a
      # contested slot of one of the single-valued members.
      def possible?(scope, hit, method_name)
        discovery = scope.discovery
        owner = hit.owner
        kind = hit.side == :singleton ? :singleton : :instance
        nodes = kind == :singleton ? :discovered_singleton_def_nodes : :discovered_def_nodes
        discovery.possible_method?(owner, method_name, kind) ||
          discovery.contested?(nodes, [owner, method_name.to_sym]) ||
          discovery.contested?(:discovered_method_visibilities, [owner, method_name.to_sym]) ||
          discovery.contested?(:discovered_parameter_envelopes, [owner, [kind, method_name.to_sym]])
      end

      def default_answer(scope, method_name, question)
        case question
        when :definer then definer_answer(scope, method_name)
        when :visibility then visibility_answer(scope, method_name)
        else raise ArgumentError, "question #{question.inspect} needs an answer function"
        end
      end

      # The first project entry with a `def` of the name, as `[def node, owner]`.
      def definer_answer(scope, method_name)
        lambda do |chain, from|
          first_hit(chain, scope, from) do |entry|
            node = if entry.side == :singleton
                     scope.singleton_def_for(entry.name,
                                             method_name)
                   else
                     scope.user_def_for(entry.name,
                                        method_name)
                   end
            [node, entry.name] if node
          end
        end
      end

      # The first project entry that records the name (a discovered method, an instance `def` the def table
      # holds, or a visibility change such as `private :foo` recorded for it), with its visibility (`:public` where
      # none was stated).
      def visibility_answer(scope, method_name)
        lambda do |chain, from|
          first_hit(chain, scope, from) do |entry|
            kind = entry.side == :singleton ? :singleton : :instance
            next unless scope.discovered_method?(entry.name, method_name, kind) ||
                        (kind == :instance && (scope.user_def_for(entry.name, method_name) ||
                                               scope.discovered_method_visibility(entry.name, method_name)))

            scope.discovered_method_visibility(entry.name, method_name) || :public
          end
        end
      end

      def first_hit(chain, scope, from)
        index = from - 1
        found = nil
        chain.search(scope, from) do |entry|
          index += 1
          next if entry.external?

          answer = yield(entry)
          next if answer.nil?

          found = Hit.new(answer, entry.name, index, entry.side)
        end
        found
      end

      private_class_method :own_hit?, :override_answer, :retro_position, :candidates, :past_fold_copies, :decided,
                           :external_may_answer?, :implicit_object_answers?, :external_lacks?,
                           :outcomes, :collapse, :possible?,
                           :default_answer, :definer_answer, :visibility_answer, :first_hit
    end
  end
end

require_relative "singleton_hook_decline"
