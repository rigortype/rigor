# rigor-activestorage

> Rigor plugin: types ActiveStorage attachment macros on AR models.

`rigor-activestorage` walks ActiveRecord model files for
`has_one_attached :avatar` / `has_many_attached :photos`
macros, records the generated attachment accessor surface,
and contributes return types when downstream code navigates
the attachment.

> **Using this plugin?** The user guide — what it infers, its
> diagnostics, configuration, and how it relates to
> `rigor-activerecord` — lives in the manual at
> [docs/manual/plugins/rigor-activestorage.md](../../docs/manual/plugins/rigor-activestorage.md).
> This README covers the plugin's internals.

## Architecture

One discovery pass per run reads the configured AR model
search paths via the plugin's `IoBoundary`, walks each
`.rb` file with Prism, and collects `has_*_attached`
declarations into an `AttachmentIndex` keyed by class name.
The walker is stand-alone (mirrors `rigor-activerecord`'s
`ModelDiscoverer`) so the plugin works even when
`rigor-activerecord` is not loaded; when it IS loaded, the
two plugins agree on what counts as a model because they
read the same source files.

The per-call return type is contributed through
`flow_contribution_for` (the supported escape valve for
method-name-gated dynamic returns); it declines on
non-`Nominal` receivers, unknown class names, attachment-name
calls with arguments (setters), and method names that don't
match a discovered attachment.

## Stand-alone vs. with `rigor-activerecord`

The plugin runs without `rigor-activerecord` — its own
discoverer reads model files independently. When
`rigor-activerecord` IS loaded, the two plugins coexist:
each surfaces its own per-call return-type contribution
and the `FlowContribution::Merger` reconciles. There is
no current dependency on the AR plugin's `:model_index`
publication (the `consumes:` row is `optional: true`); a
future slice could use it to restrict attachment recognition
to discovered AR classes only.

## No Rails runtime

Rigor stays decoupled from Rails. This plugin only reads
project source the same way the other plugins do.
