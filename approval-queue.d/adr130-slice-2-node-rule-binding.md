# `node_rule`'s block binds `node` from its class argument in the engine, not from a generated overload set

- **PR:** [#2822](https://github.com/rigortype/rigor/pull/2822)
- **Issue:** [#2686](https://github.com/rigortype/rigor/issues/2686)
- **Class:** open-choice
- **Precedent:** [#1783](https://github.com/rigortype/rigor/issues/1783)
- **Decided:** 2026-11-05

## Background

`sig/rigor/plugin/base.rbs` declares `Rigor::Plugin::Base.node_rule` with one overload each for `Prism::CallNode`, `ClassNode` and `ProgramNode` and a `Prism::Node` fallback, because RBS cannot say "the block yields instances of the class given" (`[N < ::Prism::Node] (singleton(N))` does not resolve). With the hook types live (#2768, ADR-130), two shapes bound `node` wrong and reported `call.undefined-method` on correct plugins. A class with no overload of its own (`node_rule(Prism::IfNode)`) took the fallback, so `node.predicate` reported. A class argument the engine cannot read (`def self.register(k) = node_rule(k) { ... }`) matched every overload gradually, and the block probe took the first, `Prism::CallNode`. Both comments on #2686 asked for a choice between a full generated overload set and something smaller.

## Options and trade-offs

- **Generate an overload per Prism node class** (151 under Prism 1.9) with a drift spec. It is declarative and readable by any RBS tool. It costs about 150 long lines in `base.rbs`, and it breaks loading Rigor's own `sig/` under an older Prism: the gemspec admits `prism >= 1.0, < 2.0`, and the set would name classes later minors added, which an older Prism's RBS does not declare. It also does not fix the unknown-argument case, which picks the first overload whatever the set is.
- **Fix the block probe engine-wide** so that an untyped argument binds only what every gradually matching overload agrees on, as the return path already unions them (#521). It fixes the unknown-argument case for every method, but it changes block binding across the corpus and needs a survey run, which #2686 does not ask for.
- **Rebind `node_rule`'s first block parameter from the argument** (`MethodDispatcher::ClassKeyedBlockParams`). `singleton(X)` binds `X`, a union of class objects binds the union of their instances, and anything else binds `Dynamic[top]`. The table names only `Rigor::Plugin::Base.node_rule`, keyed on the RBS owner, so a project's own `node_rule` is untouched. It is one special case in the engine, like `Integer#step`'s block parameter (#1783).

## Decision

The third. It covers every node class, including ones a later Prism adds, it needs no Prism version guard, and it changes no binding outside `Base.node_rule`. The existing overloads stay, because they state the contract correctly for the classes they name and they are what an RBS-only tool reads. The engine-wide probe bug is left for its own issue.

## To undo

Delete `lib/rigor/inference/method_dispatcher/class_keyed_block_params.rb` and its call in `RbsDispatch#probe_block_param_types_one`, the `node_rule` paragraph in `docs/internal-spec/plugin.md`, and the `node_rule` examples in `spec/integration/plugin_api_surface_spec.rb`. A generated overload set would then need a Prism version floor. Nothing else depends on the rebinding.
