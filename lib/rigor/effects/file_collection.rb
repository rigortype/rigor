# frozen_string_literal: true

require_relative "summary"

module Rigor
  module Effects
    # What one analyzed file contributes to the project's effect graph (ADR-103 WD12).
    #
    # The collector produces one of these per file and the runner marshals it back from a fork-pool worker
    # with the file's diagnostics, so every field is Marshal-clean: frozen Hashes of Strings, {Summary}
    # values, and `Data` edges. Nothing here holds a Prism node, a `Scope` or an environment.
    #
    # It carries four tables:
    #
    # - {#summaries} — the **direct** summary of each method the file defines, keyed `Class#m` / `Class.m` /
    #   `<toplevel>#m` (WD14). A reopening in another file contributes the same key and the two join.
    # - {#edges} — per method key, the calls that must be resolved against the *project* before they become
    #   graph edges. Resolution is deferred to the propagator because a file cannot see the whole class
    #   graph; the collector only records what the typer decided about the receiver.
    # - {#superclasses} / {#includes} — the ancestry the propagator needs to resolve an edge through
    #   inherited methods and to find every project-known override of a call's target (the closed-world
    #   join of WD4).
    #
    # Merging is associative and commutative in every table, so folding a run's files in pool-completion
    # order yields exactly the table sequential analysis yields.
    class FileCollection
      # One recorded call, before the project can say which definition it reaches.
      #
      # `receiver_class` is the class name the typer had at the call site (nil when it had none — a Dynamic
      # receiver, or a construct that is not a call). `kind` is `:instance` for a `Nominal` receiver and
      # `:singleton` for a `Singleton` one. `self_call` marks an implicit-self call, which is the only shape
      # whose failure to resolve is an `unresolved-self-call` taint rather than silence.
      Edge = Data.define(:receiver_class, :kind, :selector, :self_call)

      NO_TABLE = {}.freeze
      private_constant :NO_TABLE

      # The collection a file with nothing to say contributes — a parse failure, a file of constants, or a
      # run where the collector was never activated.
      def self.empty(path = nil)
        new(path: path)
      end

      attr_reader :path, :summaries, :edges, :superclasses, :includes

      def initialize(path: nil, summaries: NO_TABLE, edges: NO_TABLE,
                     superclasses: NO_TABLE, includes: NO_TABLE, failed: false)
        @path = path
        @summaries = freeze_table(summaries)
        @edges = freeze_edges(edges)
        @superclasses = freeze_table(superclasses)
        @includes = freeze_table(includes)
        @failed = failed ? true : false
        freeze
      end

      # Whether the collector gave up on this file entirely (the fail-soft path). Its methods contribute
      # nothing rather than contributing a wrong summary; `rigor check` is unaffected either way.
      def failed?
        @failed
      end

      def empty?
        @summaries.empty? && @edges.empty?
      end

      # Folds another collection into this one. Summaries join per key, edge lists union, ancestry merges.
      def merge(other)
        return self if other.empty? && !other.failed?

        self.class.new(
          path: nil,
          summaries: merge_summaries(other.summaries),
          edges: merge_edges(other.edges),
          superclasses: @superclasses.merge(other.superclasses),
          includes: merge_includes(other.includes),
          failed: @failed || other.failed?
        )
      end

      def ==(other)
        other.is_a?(FileCollection) && other.summaries == @summaries && other.edges == @edges &&
          other.superclasses == @superclasses && other.includes == @includes && other.failed? == @failed
      end
      alias eql? ==

      def hash
        [self.class, @summaries, @edges, @superclasses, @includes, @failed].hash
      end

      private

      def merge_summaries(other)
        return @summaries if other.empty?

        @summaries.merge(other) { |_key, mine, theirs| mine.join(theirs) }
      end

      def merge_edges(other)
        return @edges if other.empty?

        @edges.merge(other) { |_key, mine, theirs| (mine + theirs).uniq }
      end

      def merge_includes(other)
        return @includes if other.empty?

        @includes.merge(other) { |_key, mine, theirs| (mine + theirs).uniq }
      end

      def freeze_table(table)
        return NO_TABLE if table.empty?

        table.transform_values { |value| value.is_a?(Array) ? value.freeze : value }.freeze
      end

      # Edge lists are sorted so a marshalled worker collection and a sequential one are `==` and the
      # report they feed is byte-identical.
      def freeze_edges(table)
        return NO_TABLE if table.empty?

        table.transform_values do |list|
          list.uniq.sort_by { |edge| [edge.receiver_class.to_s, edge.kind.to_s, edge.selector] }.freeze
        end.freeze
      end
    end
  end
end
