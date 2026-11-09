# Only a direct define_singleton_method(:included) statement with a literal block is read as a hook; other definers that may define it open the read

- **PR:** [#3003](https://github.com/rigortype/rigor/pull/3003)
- **Issue:** [#2997](https://github.com/rigortype/rigor/issues/2997)
- **Class:** open-choice
- **Precedent:** [#2996](https://github.com/rigortype/rigor/pull/2996)
- **Decided:** 2026-11-09

## Background

Issue #2997 asked for the `class << self; def included` and `define_singleton_method(:included)` hook spellings to be read as `def self.included` is. It also asked that any spelling that cannot be read records `:hook_extend_open`. It did not list which spellings count as "a hook definition", nor where in a module body one may be.

## Options and trade-offs

- Read only a direct statement of the module body that has one literal hook name and a literal block with a plain first parameter. Any other call that may define the hook goes open, for each hook a computed name may spell (an interpolated name such as `"is_#{n}"`, whose literal start no hook name has, defines none):
  - a `define_singleton_method` nested in a block, condition or singleton `def`;
  - a block argument, a numbered or `it` parameter, or a second argument;
  - `send(:define_singleton_method, …)`;
  - `singleton_class.define_method`;
  - `define_method` in a `class << self` body.

  The cost is declines where Ruby would answer.
- Also read the nested and `send` forms. The read would then place an extend whose hook might not be defined, or defined later, which #2996 declines for `def self.included` bodies.
- Go open for every `define_singleton_method` in a module body, whatever its name. Includers of modules that define unrelated singleton methods this way would lose their reports.

## Decision

The first option. It mirrors #2996: only a fact the chain can place is named, and everything uncertain declines (ADR-119). Calls that define on another object are not read at all:

- a `define_singleton_method` in a `class << self` body, which defines on the singleton's singleton;
- one in an instance `def`;
- one with a literal non-hook name.

The specs pin each of these with a Ruby witness.

## To undo

Drop `record_hook_definer_calls` and its helpers (`record_hook_block`, `each_hook_definer`, `hook_definer_names`, `hook_definer_name_node`, `singleton_definer_call?`, `readable_hook_parameter`) in `lib/rigor/inference/scope_indexer.rb`, and their call in `walk_methods_and_def_nodes`. The `define_singleton_method` hook spellings then go unread again.
