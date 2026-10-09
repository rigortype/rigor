# rigor-typelizer

Teaches `rigor unused` about the serializer classes the [typelizer](https://github.com/skryukov/typelizer) gem
generates TypeScript types from. typelizer writes an interface for every named class that does
`include Typelizer::DSL` or `extend Typelizer::DSL`, and for all of its subclasses. Such a class may never be
referenced from Ruby and still be used by your frontend through the generated type, so without this plugin
`rigor unused` lists it as a removal candidate. The plugin adds no diagnostic and no return type.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-typelizer
```

## What it roots

```ruby
# app/serializers/application_serializer.rb
class ApplicationSerializer
  include Typelizer::DSL           # rooted
end

# app/serializers/user_serializer.rb
class UserSerializer < ApplicationSerializer   # rooted: a subclass of a DSL class
end

# app/serializers/event_serializer.rb
class EventSerializer
  extend Typelizer::DSL            # rooted
end

class PlainFormatter               # not rooted: no Typelizer::DSL on its chain
end
```

A subclass is followed through any chain of project classes, and a compact header such as
`class Admin::UserSerializer < Base` resolves `Base` the way Ruby does (against the lexical scope, not
`Admin`).

## What it does not root

- A class outside the configured `dirs`. typelizer generates any DSL class that is loaded, but it loads only `dirs`;
  a class elsewhere is loaded when something references it, so it is not dead.
- A `module` that includes `Typelizer::DSL`. typelizer registers the module's own name and then calls
  `.descendants` on it, which a plain module does not have, so it generates no interface.
- A DSL call that does not run with the class as `self`: inside a method, a block, a lambda or `class << self`.
- A class whose DSL comes only from an `ActiveSupport::Concern` `included do include Typelizer::DSL end` block.
  typelizer does register such a class; the plugin does not follow module hooks, so this is a missed root and the
  class stays a candidate.

`reject_class`, the lambda typelizer's configuration uses to drop a class from the output, is evaluated at
runtime and is not modelled. A rejected class is still rooted, which hides a candidate and never invents a
finding.

## Configuration

```yaml
plugins:
  - gem: rigor-typelizer
    config:
      dirs: ["app/resources", "app/serializers"]   # default
```

`dirs` mirrors `Typelizer.dirs`; the default is what `Typelizer::Railtie` sets when you configure none. Set it
to the same list you give typelizer. Superclasses are resolved over all of your project's `paths:`, so a class
that shadows a base outside `dirs` is noticed.

## More

Internals and the known limits: [plugins/rigor-typelizer/README.md](../../../plugins/rigor-typelizer/README.md).
