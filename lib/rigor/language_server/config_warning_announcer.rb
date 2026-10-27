# frozen_string_literal: true

module Rigor
  module LanguageServer
    # Issue #2231 — shows each {ConfigAudit} warning the editor has not seen yet as a `window/showMessage`
    # (`MessageType.Warning`), worded as `rigor check` prints it on STDERR. {ProjectContext#unannounced_config_warnings}
    # decides what is new, so a call after a reload that changed nothing writes nothing. Called on `initialized` and
    # after each save round's configuration reload (`DiagnosticPublisher`).
    class ConfigWarningAnnouncer
      # LSP `MessageType.Warning`, the `type` of a `window/showMessage` notification.
      MESSAGE_TYPE_WARNING = 2

      def initialize(writer:, project_context:)
        @writer = writer
        @project_context = project_context
      end

      def announce
        return unless @project_context.respond_to?(:unannounced_config_warnings)

        @project_context.unannounced_config_warnings.each do |warning|
          @writer.write(method: "window/showMessage",
                        params: { type: MESSAGE_TYPE_WARNING, message: "rigor: #{warning.message}" })
        end
      end
    end
  end
end
