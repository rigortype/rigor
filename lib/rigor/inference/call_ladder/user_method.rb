# frozen_string_literal: true

require "prism"

require_relative "../../analysis/dependency_recorder"
require_relative "../../memo_audit"
require_relative "../../reflection"
require_relative "../../type"
require_relative "../definer_resolution"
require_relative "../method_dispatcher"

module Rigor
  module Inference
    module CallLadder
      # The `user_method` rung of the call ladder (ADR-116 WD12, the first rung with a module of its own): a call on
      # an instance of a project class, answered by re-typing the body of the `def` Ruby calls, with the call's
      # argument types bound. `ExpressionTyper` asks it behind the dispatcher, in each entry `CallLadder::RUNGS` gives
      # it. {ExpressionTyper} is not required here: it requires this file, and `Scope` is loaded before either.
      #
      # Three entries, and every other function is private to the module:
      #
      # - {.try_call} is the rung, asked with the site and the walking typer.
      # - {.infer} is the same question with its arguments as positionals, for a caller that asks this rung alone
      #   with arguments that are not a site's: the own-`def` rung, and a receiver's own `send`.
      # - {.user_inference_receiver?} is the rung's gate, a predicate on the receiver type alone. The own-`def`
      #   rung's gate, the own-`send` reading and the recursion scan ask it, so it lives here once.
      #
      # The module holds no state. It reads the scope as `typer.scope` (never the site's, which `sig/` leaves
      # untyped) and calls back four methods of the typer: `class_graph_buckets`, `positional_correspondence`,
      # `infer_user_method_return` and `degrade_if_overridable`. `CallLadder::PORT` lists those five names, and
      # `spec/rigor/inference/call_ladder/port_spec.rb` fails a call on the typer that is not one of them. A function
      # that only reads the scope takes it as a parameter and never sees the typer.
      module UserMethod
        module_function

        # The rung: {.infer} for the call `site` describes. The method name is the site's, not the call node's: the
        # read of `c[k] += v` is a site whose node is the write and whose name is `[]`.
        def try_call(site, typer)
          infer(site.receiver, site.call_node, site.args, site.method_name, site.block_type, typer)
        end

        # v0.0.2 #5 — re-types the body of a user-defined instance method with the call site's argument types
        # bound to the method's parameters. Used as a last-resort tier after `MethodDispatcher.dispatch` has
        # exhausted its catalogue (RBS, shape, constant folding, user-class fallback). Returns nil when:
        #
        # - the receiver is not `Nominal[T]` for some T;
        # - no def_node is recorded for that class/method (the receiver is foreign or has only an RBS sig);
        # - the def has no body, or has a parameter shape we cannot bind from the call's positional args.
        def infer(receiver, call_node, arg_types, method_name, block_type, typer)
          return nil unless user_inference_receiver?(receiver)

          def_node, owner, raising = resolve_typing_def_with_owner(receiver.class_name, method_name, typer)
          return every_definer_raises_type(raising, receiver, call_node, arg_types, block_type, typer) if def_node.nil?

          arg_types, positionals_unknown = typer.positional_correspondence(call_node, arg_types)
          result = typer.infer_user_method_return(def_node, receiver, arg_types,
                                                  self_fold_safe: fold_safe_call_receiver?(call_node, typer.scope),
                                                  yield_type: block_type, positionals_unknown: positionals_unknown)
          return result if result.nil?

          typer.degrade_if_overridable(result, owner, method_name, :instance)
        rescue StandardError
          nil
        end

        # #525 — instance-side user-method inference accepts the named ADR-48 member carriers alongside
        # plain nominals: a `Line = Struct.new(...) do ... end` value is a StructInstance whose block defs
        # live under "Line", and the carrier itself is the right `self` for the body (member reads inside
        # the def project through it).
        def user_inference_receiver?(receiver)
          case receiver
          when Type::Nominal then true
          when Type::StructInstance, Type::DataInstance then !receiver.class_name.nil?
          else false
          end
        end

        # Issue #525 — whether the RECEIVER EXPRESSION of this call is one whose struct member map is still
        # current. Three arms:
        #
        # - a call that MATERIALISES the struct (`Point.new(…)`, `Point[…]`, `Struct.new(:x).new(…)`, a
        #   `.with(…)` copy) — the object was created by this very expression, so nothing has run against it;
        # - a local the fold-safe scan proved is never mutated / aliased / escaped;
        # - `nil` / `self`, inheriting the CURRENT body's own grant, which is what lets a chain of
        #   implicit-self readers propagate: `Line.new(…).outer` grants `outer`'s body `:self`, and an
        #   `inner` call inside it carries the grant into `inner`'s body.
        #
        # The first arm shares `StructFolding`'s materialisation test with the direct member-read gate. Neither
        # accepts a bare chained call: "chained" is not "fresh" once a method can hand back its own receiver,
        # and a self-returning fluent builder is ordinary Ruby:
        #
        #     Line = Struct.new(:text) do
        #       def with_text(v) = (self.text = v; self)
        #       def shout       = text.upcase
        #     end
        #     Line.new("a").with_text("z").shout   # runtime "Z"
        #
        # Accepting the `with_text(…)` receiver as fresh would grant `shout` a member map two statements
        # stale and fold `"A"`. Only the shapes the folding layer itself materialises qualify here.
        #
        # This is only a property of the receiver expression; whether the grant is actually issued also needs
        # a `StructInstance` carrier and a body that survives the self-use scan, both decided in
        # {ExpressionTyper#build_user_method_body_scope}.
        def fold_safe_call_receiver?(call_node, scope)
          return false if call_node.nil?

          case call_node.receiver
          when Prism::CallNode then materialization_call?(call_node.receiver, scope)
          when Prism::LocalVariableReadNode then scope.struct_fold_safe?(call_node.receiver.name)
          when nil, Prism::SelfNode then scope.struct_fold_safe?(:self)
          else false
          end
        end

        # Issue #595 — the materialisation test lives ONCE, in
        # [`struct_materialization.rb`](../method_dispatcher/struct_materialization.rb), because the direct
        # member-read gate ({MethodDispatcher::StructFolding}`#fresh_receiver?`) needs the identical answer;
        # see {MethodDispatcher::StructMaterialization.materialization_call?}. A `.with` call is never one
        # (`Struct` has no `#with`, #1335), so the test needs no lookup from either consumer.
        def materialization_call?(node, scope)
          MethodDispatcher::StructMaterialization.materialization_call?(node, scope)
        end

        # ADR-119 C2-b1 — the TYPING read of {ExpressionTyper#resolve_user_def_with_owner}: the same
        # `[def_node, owner]` pair, but answered through {DefinerResolution} so a chain that does not stand for the
        # name (a conditional definer, a conditional include, a fork, an external ancestor that may answer first) is
        # `[nil, nil]` and the call types `Dynamic` instead of from a definer Ruby may not reach. ABSENT is the same
        # `[nil, nil]`: at a typing site "no definer" and "cannot say" both fall through to the rungs below this one.
        # Existence reads ({ExpressionTyper#resolve_user_def_through_ancestors}, the self-purity scan) stay on
        # {ExpressionTyper#resolve_user_def_with_owner}'s memo: an existence read turning false there could ADD a
        # `call.undefined-method` firing.
        #
        # UNKNOWN carries a third element, the `bot` exception's definers ({.every_project_definer}): the def nodes
        # of every project entry on the chain that defines the name, or nil where the exception cannot apply.
        #
        # The memo is the typer's class-graph slot ({ExpressionTyper#class_graph_buckets}), under its `:typing_def`
        # bucket.
        def resolve_typing_def_with_owner(class_name, method_name, typer)
          cache = typer.class_graph_buckets[:typing_def]
          table = (cache[class_name.to_s] ||= {})
          key = method_name.to_sym
          if table.key?(key)
            return MemoAudit.check("class graph typing def", table[key], class_name, key) do
              compute_typing_def_with_owner(class_name, method_name, typer.scope)
            end
          end

          table[key] = MemoAudit.key_audit("class graph typing def") do
            compute_typing_def_with_owner(class_name, method_name, typer.scope)
          end
        end

        def compute_typing_def_with_owner(class_name, method_name, scope)
          case DefinerResolution.resolve(scope, class_name, method_name, :instance, question: :definer)
          in DefinerResolution::Known(answer: [node, owner])
            [node, owner]
          in DefinerResolution::UNKNOWN
            [nil, nil, every_project_definer(class_name, method_name, scope)]
          in DefinerResolution::ABSENT
            [nil, nil]
          end
        end

        # ADR-119 C2-b1 errata (the `bot` exception) — an UNKNOWN chain does not say WHICH definer Ruby calls, but
        # when every project definer of the name on the chain types `bot` (each raises or exits), the call cannot
        # return whichever of them runs, so it types `bot` and a guard such as `fail_with 'no' unless count` still
        # narrows. `defs` is {.every_project_definer}'s list; each is inferred with this call's receiver and
        # arguments, stopping at the first that returns (the answer is then `Dynamic` whatever the rest say).
        # Accepted cost: an RBS-unknown external ahead of them that really defines the name and returns is a
        # narrowing false negative; `bot` reports nothing about a value, and that exposure is master's.
        def every_definer_raises_type(defs, receiver, call_node, arg_types, block_type, typer)
          return nil if defs.nil?

          self_fold_safe = fold_safe_call_receiver?(call_node, typer.scope)
          arg_types, positionals_unknown = typer.positional_correspondence(call_node, arg_types)
          defs.each do |def_node|
            result = typer.infer_user_method_return(def_node, receiver, arg_types,
                                                    self_fold_safe: self_fold_safe, yield_type: block_type,
                                                    positionals_unknown: positionals_unknown)
            return nil unless result.is_a?(Type::Bot)
          end
          Type::Combinator.bot
        end

        # The def node of every project entry on `class_name`'s instance chain that defines `method_name`, in any
        # position (the order is what UNKNOWN does not know), or nil where the `bot` exception cannot apply: a cut
        # chain, no project definer, an entry whose only record of the name has no body (an `attr_*` or a
        # `define_method` with no `def`), a definer resting on a `possible` or contested fact (another body may be the
        # one Ruby holds), or an external RBS knows that declares the name. An external RBS does not know is passed
        # over. Only what the tables hold is read: a `define_method` beside an entry's own `def` of the name, and a
        # receiver-form `X.include(M)` outside `X`'s body, are not seen (as on the Known path).
        #
        # ADR-46: the answer depends on every entry, so each files its class edge and its negative class edge (a new
        # file reopening it may add a definer or a mixin), and each project entry's {Scope#user_def_for} files the
        # method edge, positive for a definer and `read_missing(:method, "Owner#name")` for one that lacks the
        # `def`. `DefinerResolution`'s decline filed none of this past the external that stopped it.
        def every_project_definer(class_name, method_name, scope)
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :instance, :methods)
          chain.record(scope)
          return nil if chain.truncated?

          defs = []
          declined = false
          chain.entries.uniq.each do |entry|
            if entry.external?
              note_missing_class(entry.raw.to_s.split("::").last)
              declined = true if external_declares?(entry.candidates, method_name, scope)
              next
            end
            note_missing_class(entry.last_segment)
            node = scope.user_def_for(entry.name, method_name)
            defs << node if node
            declined = true if definer_without_single_body?(entry.name, method_name, node, scope)
          end
          declined || defs.empty? ? nil : defs.freeze
        end

        def note_missing_class(segment)
          Analysis::DependencyRecorder.read_missing(:class, segment) if Analysis::DependencyRecorder.active?
        end

        def definer_without_single_body?(owner, method_name, node, scope)
          discovery = scope.discovery
          key = [owner, method_name.to_sym]
          (node.nil? && scope.discovered_method?(owner, method_name, :instance)) ||
            discovery.possible_method?(owner, method_name, :instance) ||
            discovery.contested?(:discovered_def_nodes, key)
        end

        # True where RBS knows one of the names the external's spelling can denote and declares the instance method
        # in it; a lookup that fails counts as declaring (the exception then does not apply).
        def external_declares?(candidates, method_name, scope)
          known = candidates.find { |candidate| Rigor::Reflection.rbs_class_known?(candidate, scope: scope) }
          return false if known.nil?

          !Rigor::Reflection.instance_method_definition(known, method_name, scope: scope).nil?
        rescue StandardError
          true
        end

        private_class_method :fold_safe_call_receiver?, :materialization_call?, :resolve_typing_def_with_owner,
                             :compute_typing_def_with_owner, :every_definer_raises_type, :every_project_definer,
                             :note_missing_class, :definer_without_single_body?, :external_declares?
      end
    end
  end
end
