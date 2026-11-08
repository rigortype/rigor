# Reflection.project_method_defined answers maybe on a class side that carries an open-names mark

- **PR:** [#2977](https://github.com/rigortype/rigor/pull/2977)
- **Issue:** [#2968](https://github.com/rigortype/rigor/issues/2968)
- **Class:** open-choice
- **Precedent:** [#2972](https://github.com/rigortype/rigor/pull/2972)
- **Decided:** 2026-11-08

## Background

Issue #2968 asks `Reflection.project_method_defined` to answer `maybe` (or `yes`) for any name on a Struct
whose members are splatted (`Struct.new(*FIELDS)`), so rails-routes' `unknown-helper` stays quiet. The brief
settled that the engine's existing open mechanism should carry it: the open-names marks #2897 and #2972 added,
which `call.undefined-method` reads as "this side defines names no table holds". `project_method_defined`
did not read those marks at all. Its contract said `maybe` appears exactly where the ancestor chain was cut
at its budget. Making the splat case answer `maybe` meant changing that contract, and the change reaches every
mark, not only the new Struct one.

## Options and trade-offs

- Read the marks in the `:discovered` walk (and so in `:either`), on the walked side. One rule for every open
  side: a splatted Struct or Data, `attr_accessor(*NAMES)`, `define_method` under a computed name,
  `def_delegators :@x, *NAMES`. Every plugin that tests `.no?` (rails-routes, activerecord, rspec,
  active-model-serializers) now declines on those classes. That is the safe direction for false positives, but
  it moves findings in plugins this issue never touched.
- Read only the new Struct mark. This keeps other plugins' answers unchanged, but `maybe` would then depend on
  which construct opened the class, and `attr_accessor(*NAMES)` would stay a confident `no` beside a
  `call.undefined-method` that already reads it as open.
- Record the splat's members some other way. There are none to record, since the names are unknown.

## Decision

The first option. It matches what `call.undefined-method` does through `open_names_through_ancestors?` (#2972),
so the two engine answers agree. The marks only ever turn a `no` into a `maybe`, never a `yes` into anything
else. #2972's computed-macro resolution (a body call that resolves to a class macro) is not read here: that
reader lives in `CheckRules`, and #2968 did not need it.

## To undo

Drop `open_names_on_chain?` from `lib/rigor/reflection/project_method.rb` and restore the "maybe exactly where
truncated" wording in `docs/internal-spec/reflection.md` and `public-api.md`. The rails-routes splat rows in
`spec/integration/plugins/rails_routes_plugin_spec.rb` would then report again, unless the plugin reads the
marks itself.
