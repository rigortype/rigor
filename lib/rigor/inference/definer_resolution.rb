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
    # Instance side only: `side: :singleton` raises until ADR-119 C1c designs the singleton side.
    #
    # THE CALL SITE IS A CONTRACT. A result is consumed only by an exhaustive `case/in` that is the call's own
    # direct predicate, with one arm per answer and no `else` or `in _`, and is never stored, returned or
    # truth-tested: {UNKNOWN} and {ABSENT} are both truthy, so any other use folds a decline into a firing arm.
    # `spec/rigor/inference/definer_resolution_case_in_spec.rb` fails on a call site of any other shape.
    #
    # No production reader calls it yet (ADR-119 PR C1a); it migrates one question at a time.
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
      private_constant :NONE

      module_function

      # `answer_in` is the question's per-chain answer function: called with a chain and a position, it returns
      # the {Hit} of the first project entry at or after the position that defines `method_name`, or nil. `:definer`
      # and `:visibility` have a default; every other question supplies its own. It is called once per candidate
      # on the chain, and again on the retro world when the chain has one fork, where `from` is mapped to the
      # entry it followed.
      def resolve(scope, class_name, method_name, side, question:, from: 0, &answer_in)
        raise ArgumentError, "singleton-side resolution lands with ADR-119 C1c" if side == :singleton
        raise ArgumentError, "unknown question #{question.inspect}" unless QUESTIONS.include?(question)

        answer_in ||= default_answer(scope, method_name, question)
        flavor = question == :arity ? :arity : :methods
        chain = Scope::ResolutionChain.for(scope, class_name.to_s, :instance, flavor)

        hits = candidates(scope, chain, method_name, from, answer_in)
        return UNKNOWN if hits.nil?

        verdict = chain.settle(scope, outcomes(hits), owner: hits.first&.owner, unknown_for: method_name) do |retro|
          retro_from = retro_position(chain, retro, from)
          outcomes(retro_from && candidates(scope, retro, method_name, retro_from, answer_in))
        end
        return UNKNOWN unless verdict == :chain

        collapse(hits)
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
          raise ArgumentError, "answer function went backwards" if hit && hit.index < position
          return nil if hit.nil? && chain.truncated?

          hits << hit
          return decided(scope, chain, method_name, from, hits) if hit.nil? || !possible?(scope, hit, method_name)

          position = hit.index + 1
        end
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

          Analysis::DependencyRecorder.read_missing(:class, entry.raw.to_s.split("::").last) if recording
          !Scope::ResolutionChain::Relevance.external_lacks?(scope, entry.candidates, method_name)
        end || (last.nil? && implicit_object_answers?(scope, chain, method_name))
      end

      def implicit_object_answers?(scope, _chain, method_name)
        !Scope::ResolutionChain::Relevance.external_lacks?(scope, ["Object"], method_name)
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

      # The first project entry that records the name, with its visibility (`:public` where none was stated).
      def visibility_answer(scope, method_name)
        lambda do |chain, from|
          first_hit(chain, scope, from) do |entry|
            kind = entry.side == :singleton ? :singleton : :instance
            next unless scope.discovered_method?(entry.name, method_name, kind)

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

      private_class_method :retro_position, :candidates, :decided, :external_may_answer?, :implicit_object_answers?,
                           :outcomes, :collapse, :possible?,
                           :default_answer, :definer_answer, :visibility_answer, :first_hit
    end
  end
end
