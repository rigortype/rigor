# frozen_string_literal: true

require_relative "../type"
require_relative "../inference/origin_lookup"
require_relative "attribution"
require_relative "envelope_index"
require_relative "file_collection"
require_relative "plugin_facts"
require_relative "scanner"

module Rigor
  module Effects
    # Records what the typer already decided about each call site, and turns one file's decisions into a
    # {FileCollection} (ADR-103 WD13; the contract is `docs/internal-spec/effect-summaries.md`).
    #
    # Modelled on {Rigor::Analysis::DependencyRecorder}, for the same reason: the recording site sits on
    # the per-dispatch hot path, so **the disabled fast path must be a plain integer read**. A
    # module-level activation count answers {active?} without a `Thread.current` lookup; the per-thread
    # accumulator isolates the actual recording, so a non-recording thread that sees `active?` true (a
    # sibling thread is recording) pays one extra nil-check and nothing else.
    #
    # The recorder is **observational**. It never triggers inference, never resolves what the dispatcher
    # declined, and never touches `Scope` — it reads the receiver type the typer computed anyway and the
    # `dynamic_origins` cause the typer already recorded. With no `effects:` block nothing calls
    # {collect_for}, `@active_count` stays zero, and `rigor check` is byte-identical.
    module Collector
      KEY = :__rigor_effects_collector__
      private_constant :KEY

      # What one call site decided, as the typer saw it.
      #
      # `receiver_class` / `kind` are the class the receiver's type projects to (`Nominal[Foo]` →
      # `["Foo", :instance]`, `Singleton[Time]` → `["Time", :singleton]`), nil when it projects to none.
      # `dynamic` marks a `Dynamic` receiver and `cause` carries the {Inference::DynamicOrigin} name
      # behind it, which is the detail the `dynamic-receiver` taint reports. `resolved` is false only when
      # every dispatch tier declined — the typer's own "nothing here resolved" verdict, which is what
      # separates an unresolvable implicit-self call from an ordinary one.
      CallRecord = Data.define(:receiver_class, :kind, :dynamic, :cause, :resolved)

      # Per-file, per-thread accumulator. Not frozen and never shared: it lives for one `analyze_file`.
      class Accumulator
        attr_reader :path, :calls, :attribution, :envelopes, :plugin_facts
        attr_accessor :root

        def initialize(path, attribution: Attribution.empty, envelopes: EnvelopeIndex.empty,
                       plugin_facts: PluginFacts.empty)
          @path = path
          @attribution = attribution
          @envelopes = envelopes
          @plugin_facts = plugin_facts
          # Node identity, not equality: two structurally identical call nodes in one file are different
          # sites, and `Prism::Node#hash` is structural.
          @calls = {}.compare_by_identity
          @root = nil
        end

        # First write wins. The main typing pass records a site before any re-query does (`CheckRules`
        # re-runs `type_of` over the same nodes, and a call-site-driven body re-type may visit a node a
        # second time with a different receiver), so pinning the first decision keeps a file's record
        # independent of how many times the node is visited — which is what makes pooled and sequential
        # runs agree.
        def record(node, call_record)
          @calls[node] = call_record unless @calls.key?(node)
        end

        # Whether this node's decision is already pinned. Asked BEFORE the record is built, because the
        # re-queries below are roughly half of all recording calls on a Rails app and building a record
        # only to drop it is the whole of that half's cost.
        def recorded?(node)
          @calls.key?(node)
        end

        def mark_unresolved(node)
          existing = @calls[node]
          @calls[node] = existing.with(resolved: false) if existing
        end
      end

      # Module-level activation count so {active?} is a plain integer read (GVL-atomic) rather than a
      # `Thread.current` hash lookup.
      @active_count = 0
      @mutex = Mutex.new

      module_function

      # Runs `block` with collection active for `path` and returns the resulting {FileCollection}. Nests
      # safely and restores the previous accumulator on exit.
      #
      # `attribution` is the project's `effects.attribution:` table (#385), carried on the window rather
      # than read from a global: a worker process and the parent must scan under the same table, and the
      # only thing that knows it is the configuration the run was built from. `envelopes` is the
      # {EnvelopeIndex} of #386, carried the same way and for the same reason — the declared lane a call
      # site imports must not depend on which process typed the file.
      def collect_for(path, attribution: Attribution.empty, envelopes: EnvelopeIndex.empty,
                      plugin_facts: PluginFacts.empty)
        previous = Thread.current[KEY]
        accumulator = Accumulator.new(path.to_s, attribution: attribution, envelopes: envelopes,
                                                 plugin_facts: plugin_facts)
        Thread.current[KEY] = accumulator
        @mutex.synchronize { @active_count += 1 }
        yield
        build(accumulator)
      ensure
        Thread.current[KEY] = previous
        @mutex.synchronize { @active_count -= 1 }
      end

      def active?
        @active_count.positive?
      end

      # The parsed root of the file being analyzed. Recorded by the analysis body once the parse is known
      # to have succeeded, so the scan runs over exactly what the typer saw.
      def record_root(root)
        accumulator = Thread.current[KEY]
        accumulator.root = root if accumulator && accumulator.root.nil?
      end

      # One call site's dispatch decision. `receiver` is the type the typer computed for the receiver and
      # `scope` the scope it computed it in; nothing here asks either for more.
      #
      # The `scope.source_path` guard matters: inter-procedural inference re-types a *callee's* body while
      # the caller's file is being analyzed, and those nodes belong to the callee's own file collection.
      def record_call(node, receiver, scope)
        accumulator = Thread.current[KEY]
        return if accumulator.nil? || accumulator.path != scope.source_path
        # First write wins, so a re-query has nothing to add — and asking here rather than inside
        # {Accumulator#record} is what stops it paying for the `Data` and the origin lookup below.
        return if accumulator.recorded?(node)

        dynamic = dynamic_receiver?(receiver)
        class_name, kind = descriptor_for(receiver)
        accumulator.record(
          node,
          CallRecord.new(
            receiver_class: class_name, kind: kind, dynamic: dynamic,
            cause: dynamic ? Inference::OriginLookup.origin_for(scope, node.receiver)&.to_s : nil,
            resolved: true
          )
        )
      end

      # The typer's fallback verdict: no tier resolved this call.
      def record_unresolved(node, source_path)
        accumulator = Thread.current[KEY]
        return if accumulator.nil? || accumulator.path != source_path

        accumulator.mark_unresolved(node)
      end

      # The class a receiver type projects to, as `[class_name, kind]`. A deliberately small mirror of the
      # dispatcher's own receiver descriptor: enough shapes that a fresh `[]` reads as `Array` and a
      # constant receiver as its singleton, and nothing more. An unmapped type simply has no class name,
      # which costs an edge rather than producing a wrong one.
      def descriptor_for(receiver)
        case receiver
        when Type::Nominal then [receiver.class_name, :instance]
        when Type::Singleton then [receiver.class_name, :singleton]
        when Type::Tuple then ["Array", :instance]
        when Type::HashShape then ["Hash", :instance]
        when Type::Constant then [receiver.value.class.name, :instance]
        when Type::Dynamic then descriptor_for(receiver.static_facet)
        when Type::Union then union_descriptor(receiver)
        end
      end

      # Whether the typer's verdict on this receiver leaves its class a guess. A bare `Dynamic` is the
      # original case; a union carrying a `Dynamic` arm is the same knowledge in a different shape, and
      # before #455 it was the shape that said nothing — no class, no edge, and no taint, so the summary
      # read *exhaustive* while an arm of its receiver was admittedly unknown.
      def dynamic_receiver?(receiver)
        return true if receiver.is_a?(Type::Dynamic)

        receiver.is_a?(Type::Union) && receiver.members.any?(Type::Dynamic)
      end

      # A union projects to a class exactly when its non-nil arms all project to the SAME one (#455).
      #
      # `T?` is the case that pays, and it is not a corner: ADR-58 contributes a declaration-sourced
      # `nil` to every instance variable not written in `initialize`, so **every cross-method ivar read
      # is a union** — `@group.save` reads `Group | nil` where the same `Group.new.save` two lines up
      # reads `Group`. Without this arm the receiver had no class, so the plugin row never matched, the
      # edge was dropped, and the site contributed nothing *while the summary still read exhaustive*.
      # Whether the nil arm means the call happens at all is a question for `possible-nil-receiver`; it
      # says nothing about what the call does when it does happen, which is the only question here.
      #
      # Arms that disagree (`File | StringIO`) still project to nothing. Answering with either one would
      # state an effect no single execution need perform, and answering with both is a shape the record
      # has no room for — one call site carries one receiver class.
      def union_descriptor(receiver)
        descriptors = receiver.members.reject { |member| nil_member?(member) }.map { |member| descriptor_for(member) }
        first = descriptors.first
        return nil if first.nil?

        descriptors.all? { |descriptor| descriptor == first } ? first : nil
      end

      def nil_member?(member)
        (member.is_a?(Type::Constant) && member.value.nil?) ||
          (member.is_a?(Type::Nominal) && member.class_name == "NilClass")
      end

      # Fail-soft (WD13): the scan raising drops this file's summaries and never reaches `rigor check`.
      def build(accumulator)
        return FileCollection.empty(accumulator.path) if accumulator.root.nil?

        Scanner.scan(
          root: accumulator.root, path: accumulator.path, calls: accumulator.calls,
          attribution: accumulator.attribution, envelopes: accumulator.envelopes,
          plugin_facts: accumulator.plugin_facts
        )
      rescue StandardError
        FileCollection.new(path: accumulator.path, failed: true)
      end

      private_class_method :build, :descriptor_for
    end
  end
end
