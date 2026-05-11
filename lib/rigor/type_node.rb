# frozen_string_literal: true

module Rigor
  # Mini-AST passed to plugin-supplied `TypeNode` resolvers (see
  # [ADR-13](../../docs/adr/13-typenode-resolver-plugin.md)). The
  # two leaf carriers — {Identifier} and {Generic} — describe a
  # node in an `%a{rigor:v1:...}` payload at the point the
  # built-in registry / `ImportedRefinements::Parser` failed to
  # resolve it and the analyzer hands the node off to plugins.
  #
  # Slice 1 of the ADR-13 envelope ships these two value objects
  # only. The `NameScope` companion + plugin manifest hook arrive
  # in slice 2; the parser integration arrives in slice 3. Until
  # those land, the carriers are reachable only through direct
  # instantiation in tests — they are the stable data shape every
  # later slice consumes.
  module TypeNode
  end
end

require_relative "type_node/identifier"
require_relative "type_node/integer_literal"
require_relative "type_node/generic"
require_relative "type_node/indexed_access"
require_relative "type_node/name_scope"
require_relative "type_node/resolver_chain"
