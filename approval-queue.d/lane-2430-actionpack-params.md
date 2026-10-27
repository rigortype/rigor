# Type `params[:key]` as a gradual carrier, reversing the #534 nilable answer at argument boundaries

- **PR:** [#2445](https://github.com/rigortype/rigor/pull/2445)
- **Issue:** [#2430](https://github.com/rigortype/rigor/issues/2430)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-27

## Background

`rigor-actionpack` answered a `params[:key]` read as the nilable union `ActionController::Parameters | nil`. That was adopted under #534 and #574, and `Acceptance` rejects a union with a non-`Parameters` arm at a declared boundary. So `Model.find(params[:id])` against a declared `(String id)` drew `call.argument-type-mismatch`. The value is a `String` at runtime when the param is a scalar, so the nilable nominal was a wrong type at every declared `String` boundary, with or without an actionpack RBS declaration. The issue asked for the value to cross declared boundaries gradually while the strong-parameters chain (`params[:user].permit(:name)`) kept resolving.

## Options and trade-offs

- **Keep `Parameters | nil`.** The `String` boundary false positive stays. It is the most common `params` shape in Rails controllers.
- **Dynamic over the nilable facet, plugin-only.** The subscript answers `Dynamic[ActionController::Parameters | nil]`. Two carrier-gated `dynamic_return` rules, scoped to controllers, keep `params[:user][:name]` and the strong-parameters chain resolving on the facet. Cost: a method called on the carrier outside the chain answers `Dynamic[top]` instead of its precise answer. That covers `==`, `.present?`, `.blank?` and `.to_s` (`params[:q].to_s` was `"" | String`). The cause is that the engine's composite-receiver tier projects a `Union` receiver but not a `Dynamic` one. #1101 measured that tier at 137 named-pair sites on redmine and 56 on mastodon, and the bare union used to route those sites through it, so this is the same class of loss at the call sites the union used to answer. It is precision loss, not a false positive. Recovery is #2448, which projects a `Dynamic` carrier in the composite tier.
- **Dynamic over the nilable facet, with an engine change** that projects a `Dynamic[Union]` receiver through its facet. This would keep `"" | String`, but it touches every `Dynamic` union receiver in the engine. It is out of scope for this plugin change and is filed for the coordinator as a separate issue.
- **Non-nil `Parameters`.** Rejected, as before, because it folds every `params[:k]` condition and makes a ternary over one collapse.

## Decision

The second option, plugin-only. The coordinator ruled on 2026-10-27 to keep the engine untouched. A false positive at a declared boundary is the robustness failure ADR-5 weighs most, and the precision given up (`params[:q].to_s` answering `Dynamic[top]`) is a gradual answer, not a wrong one. The #1101 spec pin that asserted `"" | String` now asserts `Dynamic[top]`, with the reason in its comment.

The precision loss is the whole class listed under the second option, not only `to_s`, and #2448 is where it is recovered. The same change brings improvements that review found: the ternary and `bot` folds on `params` chains are fixed, and the collection-case `call.undefined-method` false positives are gone. A guarded `params[:key]` local no longer draws that diagnostic when an actionpack collection declaring `ActionController::Parameters` is installed.

This partly reverses the #534 / #574 adoption: the `params[...]` answer at argument and return boundaries moves from the precise nilable union to a gradual carrier with the same facet. The #534 / #574 hazard controls are unchanged, because the facet is the same union: no truthiness fold on `params[:k] ? … : …`, no `bot` branch, and no `call.possible-nil-receiver` on `q = params[:q]; q.strip`.

## To undo

Revert the `params_read_type` answer and the two carrier-gated rules in `plugins/rigor-actionpack/lib/rigor/plugin/actionpack.rb` to the bare union. The `String` boundary false positive returns, and the actionpack integration spec's `Dynamic[ActionController::Parameters?]` dump expectations and the `Model.find` silence specs fail. Reverting also restores the #1101 `"" | String` pin. The manifest version was bumped to 1.6.0 for this change, which is a cache key and stays bumped on revert. Anything that comes to depend on the carrier, such as the engine projection route, would need to be re-measured.
