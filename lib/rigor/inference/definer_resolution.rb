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
      # The questions whose answer reads a recorded visibility: only they treat a contested visibility slot as a
      # possible definer ({#possible?}).
      VISIBILITY_QUESTIONS = %i[visibility override].freeze
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

        reads_visibility = VISIBILITY_QUESTIONS.include?(question) ? question : nil
        hits = candidates(scope, chain, method_name, from, answer_in, reads_visibility)
        return UNKNOWN if hits.nil?

        verdict = chain.settle(scope, outcomes(hits), owner: hits.first&.owner, unknown_for: method_name) do |retro|
          retro_from = retro_position(chain, retro, from)
          outcomes(retro_from && candidates(scope, retro, method_name, retro_from, answer_in, reads_visibility))
        end
        return UNKNOWN unless verdict == :chain
        return UNKNOWN if side == :singleton && SingletonHookDecline.decline?(scope, chain, method_name, from, hits)

        collapse(hits)
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
      def candidates(scope, chain, method_name, from, answer_in, reads_visibility)
        hits = []
        position = from
        loop do
          hit = answer_in.call(chain, position)
          hit = past_fold_copies(scope, chain, method_name, hit, answer_in) if chain.side == :singleton
          return nil if hit.equal?(STRAY)

          raise ArgumentError, "answer function went backwards" if hit && hit.index < position
          return nil if hit.nil? && chain.truncated?

          hits << hit
          if hit.nil? || !possible?(scope, hit, method_name, reads_visibility)
            return decided(scope, chain, method_name, from, hits)
          end

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

          Analysis::DependencyRecorder.read_missing(:class, entry.raw.to_s.split("::").last) if recording
          !external_lacks?(scope, entry.candidates, entry.side, method_name)
        end || (last.nil? && implicit_object_answers?(scope, chain, method_name))
      end

      # The implicit tail after a chain's last project superclass: `Object` (with `Kernel` and `BasicObject`) on the
      # instance side, `#<Class:Object>` through `Class`, `Module` and `Kernel` on the singleton side. It may answer
      # where RBS declares the name there, where the last class's superclass is not a constant the tables can follow
      # (#1624, {Scope::ResolutionChain#opaque_tail?}: `class C < Struct.new(:a)`, `C = Class.new(Base)`), and where
      # the project itself reopens a tail class with the name (`class Object; def self.x`), which is no entry on the
      # chain because the class names no superclass.
      def implicit_object_answers?(scope, chain, method_name)
        !external_lacks?(scope, ["Object"], chain.side, method_name) || chain.opaque_tail?(scope) ||
          project_tail_defines?(scope, chain.side, method_name)
      end

      # The implicit tail's classes and the side each is read on, per chain side: a class object reaches the instance
      # methods of `Class`, `Module`, `Object`, `Kernel` and `BasicObject` and the singleton methods of `Object` and
      # `BasicObject`.
      CLASS_OBJECT_TAIL = %w[Class Module Object Kernel BasicObject].product([:instance]) +
                          %w[Object BasicObject].product([:singleton])
      IMPLICIT_TAIL = Ractor.make_shareable({ instance: %w[Object Kernel BasicObject].product([:instance]),
                                              singleton: CLASS_OBJECT_TAIL })
      private_constant :CLASS_OBJECT_TAIL, :IMPLICIT_TAIL

      # Whether a project reopening of a tail class records the name: a `def`, whose read files the method edge, or
      # an `attr_*` / `define_method` the existence table holds.
      def project_tail_defines?(scope, side, method_name)
        IMPLICIT_TAIL.fetch(side).any? do |name, kind|
          (kind == :singleton ? scope.singleton_def_for(name, method_name) : scope.user_def_for(name, method_name)) ||
            scope.discovered_method?(name, method_name, kind)
        end
      end

      # True only for an ancestor RBS knows whose declaration lacks the name, on the side the entry stands for: an
      # external superclass on a singleton chain (`:singleton`, its whole tail) is asked for a singleton method, an
      # extended module (`:instance`) and every instance-side entry for an instance method.
      def external_lacks?(scope, candidates, side, method_name)
        Scope::ResolutionChain::Relevance.external_lacks_on?(scope, candidates, side, method_name)
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
      # contested slot of one of the single-valued members. A contested visibility slot counts only for a question
      # that reads the visibility (`reads_visibility`): a slot is contested there for a visibility call the walk
      # cannot place (an uncertain toggle, `private(*names)`, `private def self.x`), which leaves the definer and its
      # `def` certain; a possible `def` or `attr_*` call contests its def-node slot or its name's `possible` side too.
      #
      # `reads_visibility` is the question when it reads one. The `:visibility` question does not read a contested
      # instance def-node slot (#1989): it answers from the visibility slot and the name's existence, not from the
      # `def` body, and a possible `def` that contests the slot also makes its name `possible`. The slot is contested
      # alone where a later `attr_*` replaced the `def`: the attr writes the name's visibility slot, so the reader's
      # visibility is certain. A `define_method` or alias that replaced it contests the visibility slot as well, which
      # this question does read.
      #
      # Issue #2134 — the contest is a read of the slot, so a question that reads it files `visibility:<owner>#<name>`:
      # an answer block may answer from RBS without reading the slot itself (`nearest_ancestor_method_def`).
      def possible?(scope, hit, method_name, reads_visibility)
        discovery = scope.discovery
        owner = hit.owner
        kind = hit.side == :singleton ? :singleton : :instance
        nodes = kind == :singleton ? :discovered_singleton_def_nodes : :discovered_def_nodes
        Analysis::DependencyRecorder.read_visibility(owner, method_name) if reads_visibility
        discovery.possible_method?(owner, method_name, kind) ||
          (!(reads_visibility == :visibility && kind == :instance) &&
           discovery.contested?(nodes, [owner, method_name.to_sym])) ||
          (reads_visibility && discovery.contested?(:discovered_method_visibilities,
                                                    [owner, visibility_slot(method_name, kind)])) ||
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
      # none was stated). Issue #1984 — a singleton-side entry reads its class's singleton slot
      # (`private_class_method :new` records `new` there with no `def`), never the instance one.
      def visibility_answer(scope, method_name)
        lambda do |chain, from|
          first_hit(chain, scope, from) do |entry|
            kind = entry.side == :singleton ? :singleton : :instance
            recorded = side_visibility(scope, entry.name, method_name, kind)
            next unless scope.discovered_method?(entry.name, method_name, kind) || recorded ||
                        (kind == :instance && scope.user_def_for(entry.name, method_name))

            recorded || :public
          end
        end
      end

      def side_visibility(scope, owner, method_name, kind)
        if kind == :singleton
          scope.discovered_method_visibility(owner, method_name, singleton: true) ||
            self_extended_copy_visibility(scope, owner, method_name)
        else
          scope.discovered_method_visibility(owner, method_name)
        end
      end

      # Issue #2059 — a module that `extend`s itself reaches its own instance method from the singleton side, and the
      # extends fold copies that receiverless `def` onto the module's singleton entry, where no singleton slot records
      # it: the instance slot's visibility is what Ruby applies (`module ES; extend self; private def x` makes `ES.x`
      # private). A module function's singleton copy is public whatever its instance copy is, so a `module_function`
      # row for the name in any file answers nil, as does a contested instance slot.
      def self_extended_copy_visibility(scope, owner, method_name)
        node = scope.singleton_def_for(owner, method_name)
        return nil if node.nil? || !node.receiver.nil?
        return nil unless scope.discovered_extends[owner.to_s]&.include?(owner.to_s)
        return nil if scope.discovery.contested?(:discovered_method_visibilities, [owner.to_s, method_name.to_sym])
        return nil if module_function_row?(scope, owner, method_name)

        scope.discovered_method_visibility(owner, method_name)
      end

      # Whether any file's deferred ranges carry a `module_function` row (`:both` or `:singleton`) for the name on
      # `owner` (`ModuleFunctionState`).
      #
      # Issue #2161 — the answer reads every file's rows, and its edge is `visibility:<owner>#<name>`, which the one
      # caller's singleton-slot read (`side_visibility` through `Scope#discovered_method_visibility`) records for the
      # same owner and name before it asks: `ScopeIndexer.visibility_entries` carries each file's rows of this shape,
      # so a file that starts or stops writing one fires the key. A swap from `private :x` to `module_function :x` in
      # a reopening leaves the file's visibility table and declared classes as they were, and fires nothing else.
      def module_function_row?(scope, owner, method_name)
        name = method_name.to_sym
        scope.discovered_deferred_ranges.each_value.any? do |rows|
          rows.any? do |(_start, _finish, row_name, kind, row_owner)|
            row_name == name && row_owner == owner.to_s && kind != :instance
          end
        end
      end

      # The key of a name's slot in the visibility table on `kind`'s side (`ScopeIndexer#visibility_slot`).
      def visibility_slot(method_name, kind)
        kind == :singleton ? [:singleton, method_name.to_sym] : method_name.to_sym
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

      private_class_method :override_answer, :retro_position, :candidates, :past_fold_copies, :decided,
                           :external_may_answer?, :implicit_object_answers?, :project_tail_defines?, :external_lacks?,
                           :outcomes, :collapse, :possible?,
                           :default_answer, :definer_answer, :visibility_answer, :side_visibility,
                           :self_extended_copy_visibility, :module_function_row?, :visibility_slot, :first_hit
    end
  end
end

require_relative "singleton_hook_decline"
