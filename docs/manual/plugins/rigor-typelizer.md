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

- A class outside the configured `dirs`. typelizer only loads those directories.
- A `module` that includes `Typelizer::DSL`, and a class that includes such a module. typelizer registers the
  module's own name and then calls `.descendants` on it, which a module does not have, and the DSL hook never
  runs for a class that merely includes the module. Neither produces an interface, so neither is rooted.
- A DSL call inside `class << self`.

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
to the same list you give typelizer.

## More

Internals and the known limits: [plugins/rigor-typelizer/README.md](../../../plugins/rigor-typelizer/README.md).
