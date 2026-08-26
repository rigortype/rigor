# frozen_string_literal: true

require "json"

require_relative "renderable"

module Rigor
  class CLI
    # Prints what `rigor effects explain` found: for a `reach:` change, the shortest edge path from the
    # entry point to the origin that introduced the label; for a `methods:` change, the origin itself
    # (ADR-103 WD7).
    #
    #   reach:
    #     OrdersController#create → OrderService#place → PaymentGateway#charge → Net::HTTP.get [io.net.http]
    #   methods:
    #     PaymentGateway#charge [io.net.http] ← catalogue:Net::HTTP.get
    #
    # A `methods:` change has no path to walk — the label came from this method's own body — so what
    # explains it is the origin: the catalogue row or language construct, and which of the two it was.
    # Origins are line-free by design (a summary must be stable under a line move), so no position is
    # printed; call sites are per-run data the report carries.
    class EffectsExplainRenderer
      include Renderable

      # One printed explanation. `path` is empty for a `methods:` row, whose explanation is the origin;
      # `causes` is non-empty only for an exhaustiveness row, which has neither (#435).
      Row = Data.define(:table, :symbol, :label, :path, :origin, :causes)

      def initialize(out:)
        @out = out
      end

      private

      def render_text(rows)
        if rows.empty?
          @out.puts("Nothing to explain.")
          return
        end

        rows.group_by(&:table).each do |table, group|
          @out.puts("#{table}:")
          group.each { |row| @out.puts("  #{render_row(row)}") }
        end
      end

      def render_row(row)
        return "#{row.symbol} stopped being exhaustive ← #{row.causes.join(', ')}" unless row.causes.empty?
        return "#{row.path.join(' → ')} [#{row.label}]" unless row.path.empty?

        origin = row.origin ? " ← #{row.origin}" : ""
        "#{row.symbol} [#{row.label}]#{origin}"
      end

      def render_json(rows)
        @out.puts(JSON.pretty_generate(
                    "paths" => rows.map do |row|
                      {
                        "table" => row.table,
                        "symbol" => row.symbol,
                        "label" => row.label,
                        "path" => row.path,
                        "origin" => row.origin,
                        "causes" => row.causes
                      }
                    end
                  ))
      end
    end
  end
end
