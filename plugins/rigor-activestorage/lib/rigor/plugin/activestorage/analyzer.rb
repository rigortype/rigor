# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Activestorage < Rigor::Plugin::Base
      # Per-file walker. Emits one `:info` `attachment-call`
      # diagnostic per recognised attachment access on a
      # known AR class. The diagnostic surfaces what the
      # plugin recognised so users can verify the model →
      # attachment mapping the plugin sees.
      #
      # No `:error` diagnostics in this slice — the
      # `flow_contribution_for` return-type narrowing carries
      # the type-checking value; surfacing unknown attachment
      # names as errors requires a coupled receiver-class
      # narrowing pass that the integration spec doesn't yet
      # rely on. A future slice can add `unknown-attachment`
      # similar to `rigor-activerecord`'s `unknown-column`.
      class Analyzer
        attr_reader :diagnostics

        def initialize(path:, attachment_index:)
          @path = path
          @attachment_index = attachment_index
          @diagnostics = []
        end

        def analyze(root)
          walk(root) { |node| visit_call(node) if node.is_a?(Prism::CallNode) }
          self
        end

        private

        def walk(node, &)
          return if node.nil?

          yield node
          node.compact_child_nodes.each { |child| walk(child, &) }
        end

        def visit_call(node)
          return unless node.receiver.is_a?(Prism::ConstantReadNode)

          owner = node.receiver.name.to_s
          attachments = @attachment_index.attachments_for(owner) ||
                        @attachment_index.attachments_for("::#{owner}")
          return if attachments.nil?

          # Only flag when the method matches a known
          # attachment name (the `flow_contribution_for`
          # tier provides the narrowing; the diagnostic just
          # confirms the recognition).
          attachment = attachments.find { |a| a[:name] == node.name.to_s }
          return if attachment.nil?

          push_info(node, "attachment-call",
                    "`#{owner}.#{attachment[:name]}` returns " \
                    "ActiveStorage::Attached::#{attachment[:kind] == :singular ? 'One' : 'Many'}")
        end

        def push_info(node, rule, message)
          location = node.location
          @diagnostics << Rigor::Analysis::Diagnostic.new(
            path: @path,
            line: location.start_line,
            column: location.start_column + 1,
            message: message,
            severity: :info,
            rule: rule
          )
        end
      end
    end
  end
end
