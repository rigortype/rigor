# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-119 WD2 — the candidate-set read over {Scope::ResolutionChain}, for a reader that can decline. It is
    # internal (not a `Scope` method, so the pinned public surface is unchanged) and answers one of three
    # things about a method name on a class:
    #
    # - {Known} — every candidate gives the same answer to the question asked;
    # - {UNKNOWN} — the chain does not stand for this name (a mark not discharged, a fork, a retro world that
    #   answers otherwise), a candidate disagrees, or the walk was cut by the budget;
    # - {ABSENT} — nothing on the chain answers, and nothing could.
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
      # the {Hit} of the first entry at or after the position that defines `method_name`, or nil. `:definer` and
      # `:visibility` have a default; every other question supplies its own. It is called once per candidate on
      # the chain, and again on the retro world when the chain has one fork.
      def resolve(scope, class_name, method_name, side, question:, from: 0, &answer_in)
        raise ArgumentError, "unknown question #{question.inspect}" unless QUESTIONS.include?(question)

        answer_in ||= default_answer(scope, method_name, question)
        flavor = question == :arity ? :arity : :methods
        chain = Scope::ResolutionChain.for(scope, class_name.to_s, side == :singleton ? :singleton : :instance, flavor)
        hits = candidates(scope, chain, method_name, from, answer_in)
        return UNKNOWN if hits.nil?

        verdict = chain.settle(scope, outcomes(hits), owner: hits.first&.owner, unknown_for: method_name) do |retro|
          outcomes(candidates(scope, retro, method_name, from, answer_in))
        end
        return UNKNOWN unless verdict == :chain

        collapse(hits)
      end

      # The first definer and, while that definer is `possible`, the next; a nil joins the set when nothing
      # follows (the absent candidate). A cut chain is a decline, answered by nil instead of a set.
      def candidates(scope, chain, method_name, from, answer_in)
        hits = []
        position = from
        loop do
          hit = answer_in.call(chain, position)
          if hit.nil?
            return nil if chain.truncated?

            return hits << nil
          end
          hits << hit
          return hits unless possible?(scope, hit, method_name)

          position = hit.index + 1
        end
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
    end
  end
end
