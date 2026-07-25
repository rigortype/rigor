# rigor-actioncable

Tier 3F of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `<Channel>.broadcast_to(...)` and
`ActionCable.server.broadcast(stream_name, ...)` call sites against the
discovered ActionCable channel index. No `actioncable` runtime
dependency — the plugin reads project source via Prism only.

> **Using this plugin?** The user guide — recognised call shapes, the
> diagnostic catalogue, configuration, and limitations — lives in the
> manual at
> [docs/manual/plugins/rigor-actioncable.md](../../docs/manual/plugins/rigor-actioncable.md).
> This README covers the plugin's internals.

## Layout

```text
plugins/rigor-actioncable/
├── README.md
├── lib/
│   ├── rigor-actioncable.rb
│   └── rigor/plugin/
│       ├── actioncable.rb
│       └── actioncable/
│           ├── channel_index.rb       ← frozen `{class_name => Entry}` value object
│           ├── channel_discoverer.rb  ← walks app/channels, builds the index
│           └── analyzer.rb            ← per-call validation
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── app/channels/chat_channel.rb
    ├── demo.rb
    └── errors_demo.rb
```

## Running the demo

```sh
cd plugins/rigor-actioncable/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | `channel_search_paths` / `channel_base_classes` knobs (ADR-40 declared defaults). |
| `Plugin::Base.producer :channel_index` | Caches the discovered channel index across runs (cache invalidates via `producer watch:`). |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `channel_search_paths` through the trusted scope. |
| `Plugin::Base#diagnostics_for_file` | Emits the once-per-file `load-error` when channel discovery fails (file-level only). |
| `node_rule(Prism::CallNode)` (ADR-37) | Per-call validation of every `<Channel>.broadcast_to` / `ActionCable.server.broadcast` over the engine-owned walk. |
| Recursive method-body walk for DSL recognition | `stream_from` / `stream_for` calls live inside method bodies (`subscribed`); the discoverer recursively walks the channel body to find them. |
| `Plugin::Base.suggest` | Did-you-mean suggestions on two axes — channel name (`unknown-channel`) and stream name (`unknown-stream`). |
| `manifest(... protocol_contracts:)` + `Plugin::Base#protocol_contracts` override ([ADR-28](../../docs/adr/28-path-scoped-protocol-contracts.md)) | Types `#receive(data)`'s `data` as `Hash`; the `channel_search_paths` config override retargets the contract's glob the same way `rigor-hanami`'s `action_path` does. |

## Future direction

- **Cross-plugin handoff for JS side**: publish the action-method map as
  an ADR-9 fact so a hypothetical `rigor-stimulus` / `rigor-turbo` (or a
  TypeScript bridge) can validate `subscription.perform("action", data)`
  calls.
- **Indirect stream registration**: when `stream_from` is invoked inside
  a helper method (or via `extend Module`), follow the chain to recover
  the literal name.
- **Connection identifier validation**: walk `ApplicationCable::Connection`
  for `identified_by` declarations and validate that channel actions only
  reference identified attributes.
- **Subscription parameter validation**: cross-reference `params[:room_id]`
  lookups inside channels with the client-side subscription params (would
  need a JS-side consumer plugin).

## License

MPL-2.0, matching the parent Rigor project.
