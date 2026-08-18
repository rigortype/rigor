# frozen_string_literal: true

module Rigor
  module Effects
    # MEASUREMENT ONLY — the #390 census probe. Not for merge.
    #
    # Records every call in DISCARDED-STATEMENT position together with what the effect scan itself
    # decided about that site: the labels the call contributed, whether it tainted, and the project
    # edge it pushed. Rows join offline against `rigor effects --format json --full` (for a project
    # callee's transitive summary) and against `data/builtins/ruby_core/*.yml` (for the totality
    # facets), which is how the gate in #390 is evaluated without building the rule.
    #
    # Activated by `RIGOR_DISCARD_CENSUS=<file>`; a plain integer read otherwise.
    module DiscardCensus
      @io = nil
      @mutex = Mutex.new
      @path = nil

      module_function

      def active?
        return @io if defined?(@active_checked) && @active_checked

        @active_checked = true
        target = ENV.fetch("RIGOR_DISCARD_CENSUS", nil)
        @io = target && File.open(target, "a")
        @io
      end

      def path=(value)
        @path = value.to_s
      end

      # One row per discarded-position call site.
      def emit(line:, owner:, singleton:, selector:, record:, labels:, causes:, edges:, block:)
        io = active? or return

        row = [
          @path, line, owner || "-", singleton ? "." : "#", selector,
          record&.receiver_class || "-", record&.kind || "-",
          record&.dynamic ? "dyn" : "-", record.nil? || record.resolved ? "res" : "unres",
          labels.empty? ? "-" : labels.join("+"),
          causes.empty? ? "-" : causes.map { |c, d| "#{c}(#{d})" }.join("+"),
          edges.empty? ? "-" : edges.map { |e| "#{e.receiver_class}#{e.kind == :singleton ? '.' : '#'}#{e.selector}#{e.self_call ? '!self' : ''}" }.join("+"),
          block ? "blk" : "-"
        ]
        @mutex.synchronize { io.puts(row.join("\t")) }
      end
    end
  end
end
