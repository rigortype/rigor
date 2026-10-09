# rigor-alba

Teaches Rigor about the [alba](https://github.com/okuramasafumi/alba) JSON serializer. alba does not ship its
RBS in the gem, so without this plugin every alba call in your project reads `Dynamic[top]`. The plugin only
removes false diagnostics and publishes `rigor unused` roots; it adds no diagnostic and no return type.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-alba
```

## What it does

```ruby
# Inline resources: the block runs on an anonymous Alba::Resource class, so `attributes` and friends resolve
# instead of firing call.unresolved-toplevel.
json = Alba.serialize(user) { attributes :id, :name }
hash = Alba.hashify(user) { attributes :id }
```

The plugin contributes no return types: `Alba.serialize(obj)` runs your own `<Class>Resource#serialize`, which
you may override to return anything.

A block that is itself the argument of another call (`render json: Alba.serialize(x) { ... }`) is not
narrowed yet; assign the result first if you want the DSL calls inside it resolved.

## Roots for `rigor unused`

```ruby
class UserResource
  include Alba::Resource

  many :articles                               # alba loads ArticleResource, then ArticleSerializer
  one :editor, resource: EditorResource        # explicit: nothing inferred
end
```

`ArticleResource` appears nowhere in the source, so `rigor unused` would list it. The plugin publishes it as a
root. It does so only for an association that gives no `resource:` / `serializer:`, no second argument and no
block, and only when a class of the inferred name exists in the project (nesting-aware: inside `module Admin`
alba tries `Admin::ArticleResource` first). The name is classified with the real `ActiveSupport::Inflector`;
if it cannot be loaded the plugin publishes nothing.

## Configuration

```yaml
plugins:
  - gem: rigor-alba
    config:
      resource_search_paths: ["app"]   # default
```

`resource_search_paths` is where the plugin looks for resource classes. Widen it if your resources live
outside `app/`.

## More

Internals and the known limits: [plugins/rigor-alba/README.md](../../../plugins/rigor-alba/README.md).
