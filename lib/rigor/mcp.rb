# frozen_string_literal: true

module Rigor
  # The MCP (Model Context Protocol) server subsystem. See `docs/adr/33-mcp-server.md` for the design.
  #
  # Entry point: `rigor mcp --transport stdio`. The server exposes Rigor's analysis tools (check, type-of, triage,
  # annotate, sig-gen, explain, coverage) as MCP tool calls over a newline-delimited JSON-RPC 2.0 stdio stream.
  module MCP
  end
end

require_relative "mcp/server"
require_relative "mcp/loop"
