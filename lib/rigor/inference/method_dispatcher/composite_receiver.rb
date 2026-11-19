# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # The composite-receiver tier (issue #1101): a `Union` or a nil-removing `Difference` receiver is dispatched
      # once per projected member through the whole of `MethodDispatcher.resolve`, and the answers are unioned. It is
      # the last tier `resolve_site` asks, through `COMPOSITE_TIERS`, and nothing in `resolve_site` follows its
      # answer.
      #
      # The re-entry into `MethodDispatcher.resolve` is the module's one call back into the dispatcher. It passes a
      # `plugin_typed_sink:`, so a plugin tier that answers a member buffers its plugin-typed record there, and this
      # tier commits the buffer to the scope itself, only when every member answered.
      module CompositeReceiver
        module_function

        # Issue #1101 — the composite-receiver projection tier, the LAST thing `resolve_site` tries.
        #
        # Every tier above needs a receiver it can *name*: `receiver_descriptor`, the discovered-method
        # lookup, the dependency-source and synthesized-stub tiers and the user-class fallback all switch
        # on `Nominal` / `Singleton` / a member carrier. A `Union` or a `Difference` is none of those, so a
        # composite receiver whose members would each resolve perfectly well still fell through the whole
        # chain and landed `Dynamic[top]`.
        #
        # `RbsDispatch` already distributes over a `Union` (and erases a `Difference` to its base, #533),
        # but it does so INSIDE one tier, so a member that needs a LOWER tier — a user class with no RBS,
        # a discovered `def`, an opt-in gem — makes the whole union decline. That was the corpus shape before
        # #2430: rigor-actionpack typed `params[:k]` as the bare `ActionController::Parameters | nil` union, the
        # `Parameters` arm resolved only through the user-class fallback, and so `params[:k].present?` / `#==`
        # / `#blank?` / `#to_s` read opaque on every Rails app. Measured by toggling this file alone: the
        # named-pair census drained 137 sites on redmine and 56 on mastodon, and `rigor check` reported the
        # same diagnostics on both arms across eight survey targets. The plugin now answers a `Dynamic`
        # carrier, which this projection does not reach, so those off-chain calls read `Dynamic[top]` until
        # the carrier is projected here too (#2448).
        #
        # **Why the bottom and not next to `RbsDispatch`.** Sitting here, the tier can only ever replace a
        # `Dynamic[top]` the typer was about to produce — the same ADR-5 argument {UniversalObjectDispatch}
        # makes. Hoisting the projection above `RbsDispatch` would change answers that resolve today, which
        # is a different change with a different measurement.
        #
        # **The projection rule** (`receiver_projection` below; the normative statement lives in
        # [`inference-engine.md`](docs/internal-spec/inference-engine.md) § "Composite receivers"):
        #
        # - `Union[A, B, …]` projects to its members. Each is dispatched through this same chain and the
        #   results are unioned; if ANY member declines, the whole tier declines. Never a partial answer —
        #   a union whose members disagree about whether the method exists is exactly the case where an
        #   answer would be a guess.
        # - `Difference[base, nil]` projects to `base` with its nil-valued members removed. Removing `nil`
        #   from a receiver cannot change method resolution at all: `NilClass` is nobody's ancestor, so
        #   every remaining inhabitant looks a method up exactly as a plain `base` inhabitant does, and the
        #   carrier is value-set-equal to the projection. This is `T.must(x)` (rigor-sorbet's
        #   `strip_nil`), which builds `Difference[inferred(x), Constant[nil]]` — over a `T?` local that
        #   base IS a union, which is why the two arms compose rather than being separate features.
        # - Any other `Difference` DECLINES. `A − B` for a real `B` is a claim about which inhabitants
        #   survive, and the projection has nowhere to put it: dispatching on `A` re-admits exactly the
        #   overrides `B` contributed, and over a union base (`(String | Integer) − Integer` is Strings
        #   only) it re-admits a member the difference eliminated and unions in its answer — a WIDER type
        #   than today's decline, on a shape no corpus target produces. Subtracting a class from a union
        #   needs an algebra the `Difference` carrier does not have (it removes a value set, not a member),
        #   so the honest answer is to keep declining until something demands it. `RbsDispatch`'s #533
        #   erasure is untouched and still answers these for an RBS-known base.
        #
        # `self` binds to the PROJECTED receiver, not to the composite: the projection is the exact set of
        # inhabitants that can reach the method, so a `-> self` method (`dup`, `itself`, `tap`) answers per
        # member and the union reassembles them — `(String | Symbol)#itself` is `String | Symbol`. Nothing is
        # lost on the `Difference` arm because the projection is value-set-equal to the carrier there. This
        # falls out of re-entering `resolve` rather than needing a `self_type_override`.
        def try_dispatch(context)
          members = receiver_projection(context.receiver)
          return nil if members.nil? || members.size > COMPOSITE_PROJECTION_MEMBERS

          plugin_typed = []
          # Each member goes through `resolve`, which builds its context from the site's seven call fields, and not
          # through `resolve_site(context.with(receiver: member))`: `with` allocates a keyword Hash beside the
          # context, one more object for every member, and it would carry a `self_type_override` over where `self`
          # binds to the projected member (above).
          results = members.map do |member|
            MethodDispatcher.resolve(
              receiver_type: member, method_name: context.method_name, arg_types: context.args,
              block_type: context.block_type, environment: context.environment,
              call_node: context.call_node, scope: context.scope, plugin_typed_sink: plugin_typed
            )
          end
          return nil if results.any?(&:nil?)

          plugin_typed.uniq.each { |node| context.scope&.record_plugin_typed_call(node) }
          Type::Combinator.union(*results)
        end

        # An upper bound on the fan-out, because this tier re-runs the FULL dispatch chain per member.
        # Real unions are two or three members wide; a receiver wider than this is a join the engine has
        # already lost precision on, and paying N chain walks to union N answers is not worth it.
        COMPOSITE_PROJECTION_MEMBERS = 8
        private_constant :COMPOSITE_PROJECTION_MEMBERS

        # The receivers each member of a composite carrier is dispatched as, or nil when the carrier is not
        # projectable. Every member returned MUST itself be non-composite: that is what bounds the re-entry
        # into `resolve` at one level, by construction rather than by a counter — the nested call reaches
        # this tier with a receiver it declines immediately. A normalized `Union` never holds a `Union`, so
        # the shapes the guard turns away are a `Difference` over a `Difference` (`T.must(T.must(x))`) and a
        # `Union` holding one (`c ? T.must(y) : Bar.new`, which normalizes to `(A - nil) | Bar`). Both
        # decline exactly as they did before this tier existed; neither appears in the survey corpus.
        def receiver_projection(receiver)
          members =
            case receiver
            when Type::Union then receiver.members
            when Type::Difference then difference_projection(receiver)
            end
          return nil if members.nil? || members.empty?
          return nil if members.any? { |member| member.is_a?(Type::Union) || member.is_a?(Type::Difference) }

          members
        end

        # `Difference[base, nil]` projects to `base` minus its nil-valued members; every other difference
        # declines. The nil filter runs over a scalar base as well as a union one, so the rule stays total:
        # `Combinator.difference` does not normalize `NilClass - nil` (or `nil - nil`) to `Bot`, and this
        # tier must not project `[NilClass]` and answer a NilClass method for a carrier with no inhabitant.
        # Nothing observable turns on it today — `RbsDispatch`'s #533 erasure sits above this tier and
        # already answers a nil-only base from the base's own descriptor — which is why the guard is here
        # rather than in `Combinator`, where it would be a normalization change with its own blast radius.
        def difference_projection(difference)
          return nil unless nil_valued_type?(difference.removed)

          base = difference.base
          members = base.is_a?(Type::Union) ? base.members : [base]
          retained = members.reject { |member| nil_valued_type?(member) }
          return nil if retained.empty?

          retained
        end

        # `nil` as either carrier spells it: the value-pinned `Constant[nil]` the engine normally produces,
        # and the `Nominal[NilClass]` a widened or RBS-sourced position carries.
        def nil_valued_type?(type)
          (type.is_a?(Type::Constant) && type.value.nil?) ||
            (type.is_a?(Type::Nominal) && type.class_name == "NilClass")
        end
      end
    end
  end
end
