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
      #
      # `super_call` marks the edge a `super` contributes (#446). It carries the ENCLOSING unit's class and
      # selector rather than a receiver's, and the propagator resolves it against the ancestry *above* that
      # class with no closed-world override join — a different question from every other edge, which is why
      # it is a field rather than a convention over the other three.
      Edge = Data.define(:receiver_class, :kind, :selector, :self_call, :super_call) do
        # Defaulted because every producer but the `super` one records an ordinary call, and an ordinary
        # call is not a `super`.
        def initialize(super_call: false, **) = super
      end

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
      #
      # **Fold a whole run with {merge_all}, not with this in a `reduce`.** Every call here rebuilds and
      # re-freezes the accumulated tables, so folding a run one file at a time costs O(files × methods) —
      # it was 5.1 s of mastodon's 6.4 s collection overhead and the whole of gitlab's superlinear one
      # (`docs/notes/20260817-effect-collection-perf.md`). This stays for a two-collection merge, which is
      # what its cost model fits.
      def merge(other)
        return self if other.empty? && !other.failed?

        self.class.merge_all([self, other])
      end

      # Folds a run's collections in one linear pass: each key's summaries join once, each table is built
      # once, and the frozen result is constructed once at the end. Order-independent in every table
      # except `superclasses`, where a later collection's spelling wins exactly as a chain of {merge}
      # calls would leave it, so a path-sorted fold is reproducible.
      #
      # A collection that is {empty?} and not {failed?} contributes nothing, which is {merge}'s own
      # short-circuit spelled once: a file with no methods and no calls has no summary to fold, and its
      # ancestry has no unit to attach to.
      def self.merge_all(collections)
        summaries = {}
        edges = {}
        superclasses = {}
        includes = {}
        failed = false

        collections.each do |collection|
          failed ||= collection.failed?
          next if collection.empty?

          fold_summaries(summaries, collection.summaries)
          fold_lists(edges, collection.edges)
          superclasses.update(collection.superclasses)
          fold_lists(includes, collection.includes)
        end

        includes.each_value(&:uniq!)
        new(path: nil, summaries: summaries, edges: edges,
            superclasses: superclasses, includes: includes, failed: failed)
      end

      def self.fold_summaries(into, table)
        table.each do |key, summary|
          existing = into[key]
          into[key] = existing ? existing.join(summary) : summary
        end
      end
      private_class_method :fold_summaries

      # De-duplication is deferred to the single pass at the end of {merge_all} — `freeze_edges` uniqs
      # and sorts anyway, and uniqing per file is what made the fold quadratic.
      def self.fold_lists(into, table)
        table.each do |key, list|
          existing = into[key]
          existing ? existing.concat(list) : into[key] = list.dup
        end
      end
      private_class_method :fold_lists

      def ==(other)
        other.is_a?(FileCollection) && other.summaries == @summaries && other.edges == @edges &&
          other.superclasses == @superclasses && other.includes == @includes && other.failed? == @failed
      end
      alias eql? ==

      def hash
        [self.class, @summaries, @edges, @superclasses, @includes, @failed].hash
      end

      private

      def freeze_table(table)
        return NO_TABLE if table.empty?

        table.transform_values { |value| value.is_a?(Array) ? value.freeze : value }.freeze
      end

      # Edge lists are sorted so a marshalled worker collection and a sequential one are `==` and the
      # report they feed is byte-identical. The key is TOTAL over the de-duplicated list — `self_call` and
      # `super_call` are in it because two edges can otherwise agree on every other field (`def emit; super;
      # emit; end` records both), and `sort_by` is not stable.
      def freeze_edges(table)
        return NO_TABLE if table.empty?

        table.transform_values do |list|
          sorted = list.uniq
          sorted.sort_by! { |edge| edge_order(edge) }
          sorted.freeze
        end.freeze
      end

      def edge_order(edge)
        [edge.receiver_class.to_s, edge.kind.to_s, edge.selector, edge.self_call ? 1 : 0, edge.super_call ? 1 : 0]
      end
    end
  end
end
