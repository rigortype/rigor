# frozen_string_literal: true

require "json"

require_relative "renderable"

module Rigor
  class CLI
    # Prints an {EffectsReport}. Text is the review surface; JSON is what a bot reads.
    #
    # The text form says two things per method and nothing else: what it is proven to do, and whether that
    # list is complete. The `…?` suffix is the exhaustiveness bit — "these effects, and possibly more" —
    # and the indented lines under it are the closed-enum causes behind it. Deliberately not a diagnostic
    # format: no severities, no positions, no exit-code weight.
    class EffectsRenderer
      include Renderable

      def initialize(out:)
        @out = out
      end

      private

      def render_text(report)
        report.rows.each do |row|
          @out.puts("#{row.key}: [#{row.effects.join(', ')}]#{' …?' unless row.exhaustive?}")
          row.causes.each { |cause, detail| @out.puts("    #{cause}#{" (#{detail})" if detail}") }
        end
      end

      def render_json(report)
        payload = {
          "methods" => report.rows.to_h do |row|
            [row.key, {
              "effects" => row.effects,
              "exhaustive" => row.exhaustive?,
              "causes" => row.causes.map { |cause, detail| [cause, detail] },
              "direct" => row.direct
            }]
          end
        }
        @out.puts(JSON.pretty_generate(payload))
      end
    end
  end
end
