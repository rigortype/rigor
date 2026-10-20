# Close #1768 without a Grape-side ivar census

- **PR:** [#2168](https://github.com/rigortype/rigor/pull/2168)
- **Issue:** [#1768](https://github.com/rigortype/rigor/issues/1768)
- **Class:** scope
- **Precedent:** [#2099](https://github.com/rigortype/rigor/pull/2099)
- **Decided:** 2026-10-20

## Background

#1768 asked the ADR-58 class-ivar census to count writes in `define_method` blocks and in other blocks narrowed to the instance. #1957 did the `define_method` part, and #2099 did the ADR-16 `block_as_methods:` blocks whose plugin entry runs them as instance methods of the receiver (rigor-sinatra's routes and filters). #2099 left one question open: whether Grape route bodies want a census. Those bodies run on a `Grape::Endpoint` instance, not on the API class, so #2099 deliberately did not count them toward the API class. Closing #1768 needs that question answered.

## Options and trade-offs

- **No Grape census (taken).** Grape route bodies stay out of every class's census. An ivar written in one route body and read in another is not something the API class's census models anyway, since each request gets a fresh endpoint. The cost is nothing a user sees today: no Grape-side false positive from the census has been reported.
- **Count Grape route bodies toward `Grape::Endpoint`.** This models where Ruby runs them, but `Grape::Endpoint` is a gem class shared by every API in a project, so one API's writes would type every other API's reads. That is a cross-API leak with no reported need behind it.
- **Count them toward the API class.** Wrong: Ruby never sets those ivars on the API class or its instances. #2099 rejected it for that reason.

## Decision

No Grape census. The census counts a block exactly when the engine narrows its `self` to the class's instance, which is the rule #2099 applied, and a Grape route body is not such a block. If a Grape project reports a false positive that a census would fix, that is a new issue with its own fixture.

## To undo

Add the Grape plugin's route entries to the census through the same `MacroBlockSelfType.runs_as_receiver_instance_method?` match `ScopeIndexer#method_body_block_call?` uses, keyed on the class the entry binds. Nothing else depends on the omission.
