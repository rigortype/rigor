# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-116 WD12 — the order a call is typed in, declared once.
    #
    # `ExpressionTyper` types a call by asking a *ladder* of *rungs* in order, and the first that answers wins.
    # `MethodDispatcher` is one rung; what it asks inside itself are *tiers*, and their order is its own
    # (`MethodDispatcher.resolve_site`). The typer writes the ladder in full for a call, and writes a shorter
    # sequence for two other *entries*: the read a compound index write performs (`c[k] += v`) and the target of a
    # literal `send`. Sequences copied by hand drift apart (#3358), so the order and each entry's subset are
    # declared here, and `spec/rigor/inference/call_ladder_spec.rb` reads the code with Prism and fails unless
    # every method that can answer from two or more rungs asks them as these tables say.
    #
    # The engine does not load this file. The ladder stays straight-line code, no method is generated from the
    # tables and no rung is wrapped to fit them: ADR-116 rejects a table walked at run time, which would put a
    # megamorphic call on the path every call takes. The tables are for the spec, and for whoever places a rung.
    #
    # To add a rung, add its row to {RUNGS} at its position, naming the entries that ask it, and its call at that
    # position in each of those entries' methods. To move a rung's body out of the typer, change its row's `home`
    # and `asked_as`: the spec takes the spelling of every ask from the row.
    #
    # A rung whose body has moved is a module under `call_ladder/` whose entry is `try_call(site, typer)`. What it
    # may call on that typer is {PORT}, and what it exposes beside `try_call` is {SECOND_ENTRIES}:
    # `spec/rigor/inference/call_ladder/port_spec.rb` holds each rung module to both, and
    # `spec/rigor/inference/call_ladder/reentry_spec.rb` holds every other file away from {REENTRY} and the typer
    # and the rungs away from {DISPATCHER_INTERIOR}.
    module CallLadder
      # One way the typer asks the ladder. `home` is the constant, as written from `Rigor::Inference`, whose file
      # holds the entry's sequence, and `written_in` the methods there: the first starts the sequence, and each
      # later one continues it from where an earlier one calls it. `ahead` names what may answer in those
      # methods before the first rung is asked: methods of `home`, called with no receiver. Those are not rungs,
      # and nothing else there may answer.
      Entry = Data.define(:name, :home, :written_in, :ahead)

      # One rung. `asked_by` is the entries that ask it. `home` and `asked_as` spell the ask: a method of `home`,
      # called with no receiver in `home`'s own file and on the constant anywhere else. `in_typer_because` says
      # why the body is still a method of `ExpressionTyper` — the slice of ADR-116 WD12 that moves it, or why it
      # stays — and is nil for a rung whose body has a module of its own.
      Rung = Data.define(:name, :asked_by, :home, :asked_as, :in_typer_because)

      # A sequence that departs from its entry's rows, and why. With no `written_in` it holds for the entry's
      # own methods and for every branch of them. With one it is a branch: a method the entry's first method
      # returns through, held to what the entry asks ahead of that return and then to the entry's rungs less
      # `omits`, each rung named in `gates` asked through its gate.
      #
      # A row is one of two kinds. Drift is a rung the entry should ask and does not: a defect, recorded against
      # `issue`, whose fix asks the rung and deletes the row. Design has no issue and stays; ADR-116 names the one
      # there is, and another needs an amendment to it. Newly found drift needs only its row and its issue.
      ExceptionRow = Data.define(:name, :entry, :written_in, :omits, :gates, :issue, :because)

      # A rung asked through its gate: the branch tests `ask`, a second entry at the rung's home, and answers
      # `answer` where it holds, in place of asking the rung.
      Gate = Data.define(:rung, :ask, :answer)

      TYPER = "ExpressionTyper"
      private_constant :TYPER

      ENTRIES = Ractor.make_shareable(
        [
          # A call. Indexed and method-chain narrowing answers ahead of the ladder, before the operands are typed.
          Entry.new(name: :call, home: TYPER, written_in: %i[call_result_type_for dispatch_miss_result],
                    ahead: %i[indexed_narrowing_for]),
          # The `c[k]` read of `c[k] += v`. It answers nil when the ladder is exhausted, and its caller widens.
          Entry.new(name: :index_read, home: TYPER, written_in: %i[implicit_index_read_type], ahead: []),
          # The target of `recv.send(:name, …)`: the sequence inside the `literal_send` rung. A receiver with a
          # `send` of its own is answered ahead of it (`own_send_type`, which asks user-method inference alone).
          Entry.new(name: :send_target, home: TYPER, written_in: %i[try_literal_send], ahead: %i[own_send_type])
        ]
      )

      # The rungs, in the order they are asked. `asked_by` is what each entry should ask: where the code leaves a
      # rung out by mistake, the row still names the entry and {EXCEPTIONS} holds the gap against its issue.
      # `send_target` does not ask `refined` by design: a literal `send` of a name refined in effect is answered
      # by the `refined` rung of the call, which sits above `literal_send`.
      RUNGS = Ractor.make_shareable(
        [
          Rung.new(name: :refined, asked_by: %i[call index_read], home: TYPER,
                   asked_as: %i[try_refined_dispatch],
                   in_typer_because: "S4 moves it, and only with a plan for the self-typing ratchet"),
          Rung.new(name: :literal_send, asked_by: %i[call], home: TYPER,
                   asked_as: %i[try_literal_send],
                   in_typer_because: "S7 moves it, after the two rungs its own sequence asks"),
          Rung.new(name: :top_level_def, asked_by: %i[call send_target], home: TYPER,
                   asked_as: %i[try_local_def_dispatch],
                   in_typer_because: "S8 moves it"),
          Rung.new(name: :receiver_block_folds, asked_by: %i[call], home: TYPER,
                   asked_as: %i[try_receiver_block_folds],
                   in_typer_because: "stays: its methods call back eight of block typing's, the cluster #3359 " \
                                     "decides."),
          Rung.new(name: :overriding_def, asked_by: %i[call index_read send_target], home: TYPER,
                   asked_as: %i[try_overriding_def_dispatch],
                   in_typer_because: "S8 moves it, with its gate `overriding_own_def?`"),
          # Two spellings until every entry builds its site once: `dispatch` takes the call's fields as keywords,
          # `dispatch_site` the site.
          Rung.new(name: :dispatcher, asked_by: %i[call index_read send_target], home: "MethodDispatcher",
                   asked_as: %i[dispatch dispatch_site], in_typer_because: nil),
          Rung.new(name: :user_method, asked_by: %i[call index_read send_target], home: "CallLadder::UserMethod",
                   asked_as: %i[try_call], in_typer_because: nil),
          Rung.new(name: :project_singleton, asked_by: %i[call index_read send_target], home: TYPER,
                   asked_as: %i[try_project_singleton_inference],
                   in_typer_because: "S5 moves it"),
          Rung.new(name: :dynamic_receiver, asked_by: %i[call], home: TYPER,
                   asked_as: %i[inherit_receiver_origin],
                   in_typer_because: "stays: S3 was dropped. With `non_nil_retry` it is 28 code lines, and the move " \
                                     "would make `call_dispatch_type_for` public to hide them."),
          Rung.new(name: :non_nil_retry, asked_by: %i[call index_read], home: TYPER,
                   asked_as: %i[try_non_nil_receiver_retry],
                   in_typer_because: "stays: S3 was dropped, as for `dynamic_receiver`"),
          Rung.new(name: :unresolved, asked_by: %i[call], home: TYPER,
                   asked_as: %i[unresolved_call_result],
                   in_typer_because: "stays: S9 was dropped. The move would make `fallback_for` public to hide 71 " \
                                     "code lines.")
        ]
      )

      EXCEPTIONS = Ractor.make_shareable(
        [
          ExceptionRow.new(
            name: :index_read_without_refined, entry: :index_read, written_in: nil, omits: %i[refined], gates: [],
            issue: 3358,
            because: "`h[:a] += v` ignores a refinement of `[]` that `h[:a]` honours. The splat branch is held to " \
                     "what the entry asks ahead of it, so the fix asks the rung once, above the return into it."
          ),
          ExceptionRow.new(
            name: :index_read_without_non_nil_retry, entry: :index_read, written_in: nil, omits: %i[non_nil_retry],
            gates: [], issue: 3370,
            because: "`h[:a] += 1` on a receiver that may be nil reads `Dynamic[top]` where `h[:a]` reads the member."
          ),
          ExceptionRow.new(
            name: :splat_index_read, entry: :index_read, written_in: :splat_index_read_type,
            omits: %i[user_method project_singleton],
            gates: [Gate.new(rung: :overriding_def, ask: :overriding_own_def?, answer: :dynamic_top)], issue: nil,
            because: "a splat index (`c[*keys] += v`) leaves no positional argument types to bind to a body, so " \
                     "the rungs that type a body are not asked: the own-`def` rung is asked through its gate " \
                     "and answers `Dynamic[top]`, and only the dispatcher follows."
          ),
          ExceptionRow.new(
            name: :send_target_without_top_level_def, entry: :send_target, written_in: nil, omits: %i[top_level_def],
            gates: [], issue: 3369,
            because: "`send(:name, …)` on implicit `self` reads the RBS method of that name where `name(…)` reads " \
                     "the project's top-level `def`."
          ),
          ExceptionRow.new(
            name: :send_target_without_overriding_def, entry: :send_target, written_in: nil,
            omits: %i[overriding_def], gates: [], issue: 3368,
            because: "`x.send(:name)` reads a declaration a project ancestor wrote where `x.name` reads the " \
                     "receiver's own `def`."
          )
        ]
      )

      # The typer's re-entry points: methods of `ExpressionTyper` that are public only so that a rung module can call
      # them on the typer it is given, each `@api private`. They run the typer's own code, which reads its cursor
      # (the node `type_of` is typing) and the frames `TypingState` pushes and pops around a body, so they mean
      # something only inside the `type_of` walk that asked the rung. Nothing outside `call_ladder/` calls one on a
      # typer it holds. A slice adds a name here when its rung first needs it, and makes the method public then.
      REENTRY = Ractor.make_shareable(
        %i[
          class_graph_buckets
          positional_correspondence
          infer_user_method_return
          degrade_if_overridable
        ]
      )

      # The port: every method of the typer a rung module may call on the `typer` it is given, `send` and the
      # other reflective calls being none of them. `scope` reads the frame's scope; a rung reads it there and never
      # from its site, whose `scope` `sig/` leaves untyped. The rest are {REENTRY}. A rung that needs a fifth
      # re-entry point of its own does not move (ADR-116, the #3318 cut-off): the list is not widened to fit one.
      PORT = Ractor.make_shareable([:scope, *REENTRY])

      # A function a rung module exposes beside its rung's `asked_as`, for a caller that asks part of the rung with
      # arguments that are not a site's. `home` is the module, as a rung's `home` is. `given_typer` says whether the
      # entry takes the typer, and so may use {PORT}; one that does not is a function of its arguments alone, and
      # names neither a typer nor a scope. ADR-116's amendment names each entry: a new one is a row here and its
      # name there.
      SecondEntry = Data.define(:home, :name, :given_typer, :because)

      SECOND_ENTRIES = Ractor.make_shareable(
        [
          SecondEntry.new(
            home: "CallLadder::UserMethod", name: :infer, given_typer: true,
            because: "the own-`def` rung and a receiver's own `send` ask this rung alone, with a method name and " \
                     "argument types that are not their site's, so it takes them as positionals."
          ),
          SecondEntry.new(
            home: "CallLadder::UserMethod", name: :user_inference_receiver?, given_typer: false,
            because: "the rung's gate, a predicate on the receiver type. The own-`def` rung's gate, the own-`send` " \
                     "reading and the recursion scan ask it too, so it moved with the rung: left in the typer it " \
                     "was the rung's fifth callback."
          )
        ]
      )

      # The dispatcher's interior: entries of `MethodDispatcher` that only the dispatcher and the tiers that dispatch
      # again call (`MethodDispatcher::ProjectPatched`, `MethodDispatcher::CompositeReceiver`). They skip the records
      # `dispatch_site` makes after an answer, so the typer and the rung modules ask the dispatcher by its row's
      # `asked_as` and never by one of these.
      DISPATCHER_INTERIOR = Ractor.make_shareable(%i[resolve resolve_site])
    end
  end
end
