# frozen_string_literal: true

module Rigor
  # The Language Server subsystem. See
  # `docs/design/20260517-language-server.md` for the design.
  # Slice 1 ships the namespace + a minimal {Server} lifecycle the
  # `rigor lsp` CLI subcommand can drive. Later slices add the
  # stdio JSON-RPC transport (slice 2), the BufferTable (slice 3),
  # `publishDiagnostics` (slice 4), and the rest of the v1 capability
  # surface.
  module LanguageServer
  end
end

require_relative "language_server/server"
require_relative "language_server/loop"
