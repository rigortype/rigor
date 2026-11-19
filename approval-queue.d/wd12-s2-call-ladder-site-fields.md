# A site leaves `self_type_override` and `public_only` at their defaults, and nothing outside the dispatcher's directory sets them

- **PR:** [#3367](https://github.com/rigortype/rigor/pull/3367)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

`MethodDispatcher::CallContext` has nine fields. Seven describe a call. The other two, `self_type_override` and `public_only`, are set by the user-class fallback on a context it derives for the RBS-backed tier: it looks the method up on `Object` and needs to say that `self` is still the original receiver, and that a call written on an explicit receiver must not reach a private method.

Slice S1 of ADR-116's WD12 amendment (#3366) added `MethodDispatcher.dispatch_site(context)`, the entry for a caller that has built the context itself. Until then no caller of the dispatcher could set the two fields, because `dispatch` takes seven keywords. #3366 measured that no context reaching the ladder sets either, wrote "what a site that sets them answers is not specified" into `docs/internal-spec/inference-engine.md`, and left the question open. The rung slices from S6 on build sites, so the brief for S2′ asked for a rule a rung can read.

What happens today was probed on the merge base. Only the RBS-backed tier reads the two fields, for the receiver's own lookup. The user-class fallback replaces both on the context it derives. A call the dispatcher dispatches again is built without them, since neither `dispatch` nor `resolve` takes them: the parts of an optional count, an alias target and a composite receiver's members through `resolve`, the `BoundMethod` backward fold and the `reduce` operator fold through `dispatch`. So with `public_only: true` on the site, `String#puts` does not resolve and `(String | Integer)#puts` does, through the composite tier.

## Options and trade-offs

- **Specify what happens today.** A site may set the fields and gets what the tiers do with them. A rung that set `public_only` would get a call that is public-only for some receivers and not for others, with nothing failing.
- **Make the dispatcher honour them.** Thread both through the re-entries and the fallback. That is a behaviour change with its own questions (what `self` a composite member binds under an override), in a slice whose claim is that no behaviour changes. For `public_only` it is also [ADR-132](../docs/adr/132-reflective-call-view.md) WD3's work: that ADR, accepted with no slice landed, makes visibility a field of the call and has the literal `send` set it.
- **Refuse them at `dispatch_site`.** A raise for a site that sets either. It adds a check to every dispatch (2,298,994 in one check of `lib`, #3366's count) to catch a mistake a static check can catch for nothing.
- **Forbid them on a site, and check the code.** The fields stay a tier's. Nothing outside `lib/rigor/inference/method_dispatcher/` sets either on a context, and a spec fails when something does.

## Decision

A site MUST leave both fields at their defaults, and code outside `lib/rigor/inference/method_dispatcher/` MUST NOT set either on a context. `docs/internal-spec/inference-engine.md` § "Method Dispatch Boundary" says so, and says what a site that set one would get, in place of "not specified". The dispatcher does not check.

`spec/rigor/inference/method_dispatcher/dispatch_site_spec.rb` holds it in the group "a site's two other fields". Two examples read `lib/`, the plugins and the examples with Prism: no file outside the dispatcher's directory passes either field to `CallContext.build` or to a context's `with`, or calls `CallContext.new`; and only `rbs_dispatch.rb` reads them off a context. Another pins that neither keyword entry accepts them. Two more pin what the internal spec says such a site would get, so the description cannot go stale unnoticed.

The two that read the code know a context by its spelling: the `CallContext` class, a context built or derived in place, a local the same file assigns one to, and anything named `context` or `site`. They do not key on the field names alone, because ADR-132 WD1's `Invocation` has a `public_only` field of its own and lands before WD3; an example pins that such a value trips neither. A context held under another name is not seen.

The precedent is the amendment's definition of a site: "*`site` is the call.* It is built once per site with `CallContext.build`". A property of a derived lookup is not part of the call. It fits closely for `self_type_override`, which has no meaning for a call. For `public_only` it fits until ADR-132 WD3 lands: that slice will let a site set the field, and the internal spec now says it must thread the field through the re-entries and the fallback when it does.

## To undo

To let a site set `public_only`, which is what ADR-132 WD3 does: carry the field through `MethodDispatcher.resolve` and `dispatch` (or switch the re-entries to a context copy), decide what the user-class fallback does with a value it is given, then change the paragraph in § "Method Dispatch Boundary", the comment on `MethodDispatcher.dispatch_site`, and the group "a site's two other fields": its first example's directory rule, its second example if another tier starts reading the field, and the two examples that pin today's partial reading.

Nothing depends on the rule yet. The rung slices of WD12 build sites from the seven call fields and need neither field.
