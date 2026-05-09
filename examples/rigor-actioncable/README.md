# rigor-actioncable

Tier 3F of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `<Channel>.broadcast_to(...)` and
`ActionCable.server.broadcast(stream_name, ...)` call
sites against the discovered ActionCable channel index.
No `actioncable` runtime dependency — the plugin reads
project source via Prism only.

## What the plugin recognises

Given a channel class:

```ruby
# app/channels/chat_channel.rb
class ChatChannel < ApplicationCable::Channel
  def subscribed
    stream_from "chat_room_5"
  end

  def speak(data)
    # ...
  end
end
```

…the plugin validates every broadcast call site:

```text
demo.rb:24:1: info: `ChatChannel.broadcast_to(...)` matches discovered channel
demo.rb:30:1: info: `broadcast("chat_room_5", ...)` matches a registered `stream_from`

errors_demo.rb:19:1: error:   no ActionCable channel `ChartChannel` (did you mean `ChatChannel`?)
errors_demo.rb:24:1: warning: no `stream_from "chat_room_42"` registration in any discovered channel (did you mean `"chat_room_5"`?)
```

## Recognised call shapes

| Shape | What gets checked |
| --- | --- |
| `<X>Channel.broadcast_to(record, data)` | `<X>Channel` exists in the index |
| `ActionCable.server.broadcast("stream", data)` | `"stream"` is registered via `stream_from` in some channel |
| `<NonChannelClass>.broadcast_to(...)` | Silently passed through (likely an unrelated method) |
| `ActionCable.server.broadcast(variable, ...)` | Silently passed through (non-literal) |

## What it checks

1. **Channel-class existence** — `<X>.broadcast_to(...)`
   where `<X>` ends in `Channel` must resolve to a
   discovered channel; otherwise an `unknown-channel`
   error fires with a `DidYouMean::SpellChecker`
   suggestion.
2. **Stream-name registration** —
   `ActionCable.server.broadcast("stream_name", ...)`
   with a literal stream name is checked against every
   discovered channel's `stream_from "..."` calls. The
   check is suppressed when ANY discovered channel has a
   dynamic registration (`stream_from interpolated_string`
   or `stream_for record`) — the absence of a literal
   match doesn't prove absence.

## Configuration

```yaml
plugins:
  - gem: rigor-actioncable
    config:
      channel_search_paths: ["app/channels"]                                # default; optional
      channel_base_classes: ["ApplicationCable::Channel", "ActionCable::Channel::Base"]  # default; optional
```

## Limitations (v0.1.0)

- **Direct-superclass match only.** `class AdminChannel
  < BaseChannel < ApplicationCable::Channel` requires
  `BaseChannel` listed in `channel_base_classes`.
- **Action method invocations are not validated.**
  ActionCable actions are invoked from JavaScript via
  `subscription.perform("action_name", data)`; we don't
  analyse JS, so the action-method index is currently
  informational only. A future cross-plugin handoff
  could publish the action map for a hypothetical JS-side
  analyzer.
- **`broadcast_to` arity is not checked.** The method
  takes any record + any data hash; there's no useful
  arity envelope.
- **Indirect stream registration** (a helper method
  defined elsewhere that calls `stream_from`) is out of
  scope — only `stream_from` / `stream_for` calls
  *inside* a discovered channel's body are recognised.
- **Single-symbol `broadcast(...)` calls** without an
  explicit `ActionCable.server` receiver are skipped to
  avoid false positives on unrelated `broadcast` methods.

## Layout

```text
examples/rigor-actioncable/
├── README.md
├── rigor-actioncable.gemspec
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
cd examples/rigor-actioncable/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | Optional `channel_search_paths` / `channel_base_classes` knobs. |
| `Plugin::Base.producer :channel_index` | Caches the discovered channel index across runs. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `channel_search_paths` through the trusted scope. |
| `Plugin::Base#diagnostics_for_file` | Per-file walker validates every `<Channel>.broadcast_to` and `ActionCable.server.broadcast` call. |
| Recursive method-body walk for DSL recognition | `stream_from` / `stream_for` calls live inside method bodies (`subscribed`); the discoverer recursively walks the channel body to find them. |
| Did-you-mean suggestions on TWO axes | One on the channel name (`unknown-channel`), one on the stream name (`unknown-stream`). |

## Future direction

- **Cross-plugin handoff for JS side**: publish the
  action-method map as an ADR-9 fact so a hypothetical
  `rigor-stimulus` / `rigor-turbo` (or even a TypeScript
  bridge) can validate `subscription.perform("action",
  data)` calls.
- **Indirect stream registration**: when `stream_from`
  is invoked inside a helper method (or via
  `extend Module`), follow the chain to recover the
  literal name.
- **Connection identifier validation**: walk
  `ApplicationCable::Connection` for `identified_by`
  declarations and validate that channel actions only
  reference identified attributes.
- **Subscription parameter validation**: cross-reference
  `params[:room_id]` lookups inside channels with the
  client-side subscription params (would need a JS-side
  consumer plugin).

## License

MPL-2.0, matching the parent Rigor project.
