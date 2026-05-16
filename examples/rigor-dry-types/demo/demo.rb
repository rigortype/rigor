# frozen_string_literal: true

# rigor-dry-types demo. Run from this directory:
#
#   cp .rigor.dist.yml .rigor.yml
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# The canonical dry-types alias-module declaration. With the
# plugin enabled, rigor's prepare(services) hook scans this
# file, sees `include Dry.Types()` inside `module Types`, and
# publishes the `:dry_type_aliases` fact mapping
# `Types::String` → `String`, `Types::Integer` → `Integer`,
# etc.
#
# At slice 1 the observable change is fact-publication only;
# the downstream uplift (e.g., promoting `rigor-dry-struct`
# reader returns from Dynamic[T] to Nominal[String]) lands in
# a later slice that wires the fact through the dispatcher.

module Types
  include Dry.Types()
end
