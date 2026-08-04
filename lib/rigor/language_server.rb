# frozen_string_literal: true

module Rigor
  # The Language Server subsystem. See `docs/design/20260517-language-server.md` for the design. The full v1
  # capability surface (document sync, publishDiagnostics, hover, completion, sig-help, folding, selection, and
  # watched-file invalidation) is implemented. This module is the namespace and require entry point for the
  # subsystem.
  module LanguageServer
  end
end

require_relative "language_server/incremental_sync"
require_relative "language_server/buffer_table"
require_relative "language_server/uri"
require_relative "language_server/project_context"
require_relative "language_server/debouncer"
require_relative "language_server/publish_batcher"
require_relative "language_server/synchronized_writer"
require_relative "language_server/diagnostic_publisher"
require_relative "language_server/hover_renderer"
require_relative "language_server/hover_provider"
require_relative "language_server/completion_provider"
require_relative "language_server/signature_help_provider"
require_relative "language_server/document_symbol_provider"
require_relative "language_server/folding_range_provider"
require_relative "language_server/selection_range_provider"
require_relative "language_server/server"
require_relative "language_server/loop"
