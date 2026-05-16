# frozen_string_literal: true

# The canonical dry-types alias-module declaration. With
# `rigor-dry-types` loaded, this file's scan publishes
# `Types::String` -> "String", `Types::Bool` -> "TrueClass",
# etc. as the `:dry_type_aliases` cross-plugin fact. The
# `rigor-dry-struct` plugin (also loaded) consumes that fact
# through ADR-18's `returns_from_arg:` so each
# `attribute :name, Types::String` line synthesises a reader
# returning `Nominal[String]` instead of `Dynamic[Top]`.

module Types
  include Dry.Types()
end
