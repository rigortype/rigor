# rigor-actioncable

Validates ActionCable broadcast call sites against a statically
discovered channel index: `<X>Channel.broadcast_to(record, data)`
checks that the channel class exists, and
`ActionCable.server.broadcast("stream_name", data)` checks that the
literal stream name was registered with `stream_from` in some channel.
It reads source only — no `actioncable` runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-actioncable
```

## What it checks

```ruby
# app/channels/chat_channel.rb
class ChatChannel < ApplicationCable::Channel
  def subscribed
    stream_from "chat_room_5"
  end
end

ChatChannel.broadcast_to(room, message: "hi")               # info:  channel exists
ActionCable.server.broadcast("chat_room_5", body: "hi")     # info:  registered stream
ChartChannel.broadcast_to(room, message: "hi")              # error: no channel (did you mean ChatChannel?)
ActionCable.server.broadcast("chat_room_42", body: "hi")    # warning: no such stream registration
```

| Rule | Severity | Fires when |
| --- | --- | --- |
| `plugin.actioncable.broadcast-target` | info | `<X>Channel.broadcast_to(...)` matched a discovered channel |
| `plugin.actioncable.broadcast-stream` | info | `ActionCable.server.broadcast("...", ...)` matched a registered `stream_from` literal |
| `plugin.actioncable.unknown-channel` | error | the receiver ends in `Channel` but is not in the index (with a did-you-mean) |
| `plugin.actioncable.unknown-stream` | warning | the literal stream name matched no `stream_from` registration (with a did-you-mean) |
| `plugin.actioncable.load-error` | warning | channel discovery failed (parse/read error) — once per file |

The `unknown-stream` check is **suppressed** when any discovered
channel registers a dynamic stream (`stream_from interpolated_string`
or `stream_for record`) — the absence of a literal match doesn't prove
the stream is invalid. Non-`Channel` receivers and non-literal stream
arguments pass through silently.

## `#receive(data)` parameter typing

The plugin also carries an [ADR-28](../../adr/28-path-scoped-protocol-contracts.md)
path-scoped protocol contract: inside any `#receive(data)` defined
under `channel_search_paths`, `data` types as `Hash` instead of
`Dynamic[Top]`. `#receive` is ActionCable's framework-dispatched
catch-all action — invoked with the decoded JSON payload when an
incoming message carries no `"action"` key — so the parameter shape is
uniform across every channel.

```ruby
# app/channels/chat_channel.rb
class ChatChannel < ApplicationCable::Channel
  def receive(data)
    data["body"]           # data: Hash
    data.no_such_method    # error: call.undefined-method
  end
end
```

Custom action methods (`def speak(data)`) are not covered — their
names are project-chosen, and a protocol contract names a single fixed
method. Only `#receive` is a reserved, uniformly-shaped hook.

## Configuration

```yaml
plugins:
  - gem: rigor-actioncable
    config:
      channel_search_paths: ["app/channels"]                                            # default
      channel_base_classes: ["ApplicationCable::Channel", "ActionCable::Channel::Base"] # default
```

`channel_search_paths` also retargets the `#receive` protocol
contract's glob — including for multiple configured roots — so a
custom channel directory gets the same `data: Hash` typing as the
default.

## Limitations

- **Direct-superclass match only.** An indirect chain (`AdminChannel <
  BaseChannel < ApplicationCable::Channel`) needs `BaseChannel` listed
  in `channel_base_classes`.
- **Action methods are indexed, not validated.** Channel actions are
  invoked client-side via `subscription.perform("action", data)`; Rigor
  does not analyse JavaScript, so the action index is informational.
- **`broadcast_to` arity is not checked** — it accepts any record + any
  data hash.
- **Indirect `stream_from`** (registered inside a helper method rather
  than directly in the channel body) is out of scope.
- **Bare `broadcast(...)`** without an explicit `ActionCable.server`
  receiver is skipped to avoid false positives on unrelated methods.
- **The `#receive` contract is path-scoped, not class-scoped** (ADR-28):
  any `def receive(data)` defined anywhere under `channel_search_paths`
  is typed, even on a class that isn't an ActionCable channel.

## Plugin internals

The channel discoverer / index and the contract surfaces this plugin
exercises are in the
[plugin's README](../../../plugins/rigor-actioncable/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
