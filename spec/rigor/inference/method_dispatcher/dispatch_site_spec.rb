# frozen_string_literal: true

require "spec_helper"

# `MethodDispatcher`'s entries (ADR-116 WD12 S1). `dispatch_site(context)` takes a site its caller built and answers
# what `dispatch` answers for the same seven fields; `dispatch` is that entry behind one `CallContext.build`.
# `resolve` builds the context the same way and hands it, with a re-entry's two flags, to `resolve_site`, which is the
# one place that holds the nil-receiver guard, the optional-count split and the tier order.
RSpec.describe Rigor::Inference::MethodDispatcher, ".dispatch_site" do
  def comb = Rigor::Type::Combinator
  def dispatcher = described_class
  def context_class = Rigor::Inference::MethodDispatcher::CallContext
  def string = comb.nominal_of("String")
  def symbol = comb.nominal_of("Symbol")
  def one = comb.constant_of(1)
  def two = comb.constant_of(2)
  def nil_constant = comb.constant_of(nil)
  def pair = Rigor::Type::Tuple.new([one, two])

  let(:environment) { Rigor::Environment.default }
  let(:call_node) { Prism.parse("widget.render(1)").value.statements.body.first }

  # The site `dispatch` builds for a set of its keywords.
  def site_for(receiver_type:, method_name:, arg_types:, **rest)
    cc(receiver: receiver_type, method_name: method_name, args: arg_types, **rest)
  end

  # A scope whose project source records `render` on `Widget` and holds no body for it, so the discovered-method tier
  # answers the call and `resolve_site` records where the `Dynamic` came from.
  def widget_scope
    empty = Rigor::Scope.empty(environment: environment)
    index = empty.discovery
    empty.with_discovery(index.with(discovered_methods: { "Widget" => { render: :instance } },
                                    possible_discovered_methods: index.possible_discovered_methods))
  end

  # One call per way of answering: a precise fold, the RBS tier with and without a block, the user-class fallback, the
  # composite tier (which re-enters once a member), the optional-count split (which re-enters once a part), and the
  # two declines. None of them needs a call node or a scope; the example after the table's is the one that does.
  def representative_calls
    {
      "a constant fold" => [{ receiver_type: one, method_name: :+, arg_types: [two] }, comb.constant_of(3)],
      **calls_the_signatures_answer, **calls_that_dispatch_again,
      "a call no tier answers" => [{ receiver_type: comb.top, method_name: :zz, arg_types: [] }, nil],
      "a call with no receiver type" => [{ receiver_type: nil, method_name: :zz, arg_types: [] }, nil]
    }
  end

  def calls_the_signatures_answer
    integers = comb.nominal_of("Array", type_args: [comb.nominal_of("Integer")])
    {
      "an RBS answer" =>
        [{ receiver_type: symbol, method_name: :to_proc, arg_types: [], environment: environment },
         comb.nominal_of("Proc")],
      "an RBS answer that binds the block's return" =>
        [{ receiver_type: integers, method_name: :map, arg_types: [], block_type: string, environment: environment },
         comb.nominal_of("Array", type_args: [string])],
      "the user-class fallback" =>
        [{ receiver_type: rbs_less, method_name: :to_s, arg_types: [], environment: environment }, string]
    }
  end

  def calls_that_dispatch_again
    {
      "a composite receiver" =>
        [{ receiver_type: comb.union(rbs_less, nil_constant), method_name: :to_s, arg_types: [],
           environment: environment }, comb.union(comb.constant_of(""), string)],
      "a nil count" =>
        [{ receiver_type: pair, method_name: :min, arg_types: [nil_constant], environment: environment }, one]
    }
  end

  # A class no RBS knows, which only the user-class fallback answers.
  def rbs_less = comb.nominal_of("ProjectOnlyWidget")

  describe "the four entries" do
    it "answer the same for a call, by keywords and by the site built from them" do
      representative_calls.each do |name, (keywords, expected)|
        site = site_for(**keywords)

        expect(dispatcher.dispatch_site(site)).to eq(expected), "dispatch_site, #{name}"
        expect(dispatcher.dispatch(**keywords)).to eq(expected), "dispatch, #{name}"
        expect(dispatcher.resolve_site(site)).to eq(expected), "resolve_site, #{name}"
        expect(dispatcher.resolve(**keywords)).to eq(expected), "resolve, #{name}"
      end
    end

    it "read the site's call node and scope: a discovered method answers, and the origin of its Dynamic is recorded" do
      widget = comb.nominal_of("Widget")
      origin = Rigor::Inference::DynamicOrigin::INFERRED_RETURN_UNTYPED
      entries = {
        dispatch_site: ->(scope) { dispatcher.dispatch_site(site_for(**keywords_for(widget, scope))) },
        dispatch: ->(scope) { dispatcher.dispatch(**keywords_for(widget, scope)) },
        resolve_site: ->(scope) { dispatcher.resolve_site(site_for(**keywords_for(widget, scope))) },
        resolve: ->(scope) { dispatcher.resolve(**keywords_for(widget, scope)) }
      }

      entries.each do |name, entry|
        scope = widget_scope

        expect(entry.call(scope)).to eq(comb.untyped), name.to_s
        expect(scope.dynamic_origin(call_node)).to eq(origin), name.to_s
      end
      # Without the scope the tier has no table to read, and the fallback answers nothing for `render`.
      expect(dispatcher.dispatch_site(site_for(**keywords_for(widget, nil)))).to be_nil
    end

    def keywords_for(receiver, scope)
      { receiver_type: receiver, method_name: :render, arg_types: [one], environment: environment,
        call_node: call_node, scope: scope }
    end
  end

  # Doubles stand for the environment and the scope where the entry under test only passes them on.
  describe "what each entry passes on" do
    let(:answer) { symbol }
    let(:block) { comb.nominal_of("Proc") }
    let(:environment) { instance_double(Rigor::Environment) }
    let(:scope) { instance_double(Rigor::Scope) }
    let(:keywords) do
      { receiver_type: string, method_name: :fetch, arg_types: [one], block_type: block, environment: environment,
        call_node: call_node, scope: scope }
    end

    it "dispatch builds one context from its seven keywords and hands it to dispatch_site" do
      site = site_for(**keywords)
      allow(dispatcher).to receive(:dispatch_site).and_return(answer)
      allow(context_class).to receive(:build).and_call_original

      expect(dispatcher.dispatch(**keywords)).to equal(answer)
      expect(dispatcher).to have_received(:dispatch_site).with(site).once
      expect(context_class).to have_received(:build).once
    end

    it "resolve builds one context from the same seven and hands it to resolve_site with the two flags" do
      site = site_for(**keywords)
      sink = []
      allow(dispatcher).to receive(:resolve_site).and_return(answer)
      allow(context_class).to receive(:build).and_call_original

      expect(dispatcher.resolve(**keywords, plugin_typed_sink: sink, skip_project_patched: true)).to equal(answer)
      expect(dispatcher).to have_received(:resolve_site)
        .with(site, plugin_typed_sink: equal(sink), skip_project_patched: true).once
      expect(context_class).to have_received(:build).once
    end

    it "resolve leaves the sink unset and the project-patched tier on when the caller sets neither flag" do
      site = site_for(**keywords)
      allow(dispatcher).to receive(:resolve_site)

      dispatcher.resolve(**keywords)

      expect(dispatcher).to have_received(:resolve_site).with(site, plugin_typed_sink: nil, skip_project_patched: false)
    end

    # Neither keyword entry looks at the call: one with no receiver type, and one whose count is nil, reach the site
    # entry as they were written, so the guard and the split have no second copy to disagree with.
    it "dispatch and resolve check nothing themselves" do
      no_receiver = { **keywords, receiver_type: nil }
      nil_count = { **keywords, receiver_type: pair, method_name: :min, arg_types: [nil_constant] }
      sites = [site_for(**no_receiver), site_for(**nil_count)]
      allow(dispatcher).to receive_messages(dispatch_site: answer, resolve_site: answer)

      [no_receiver, nil_count].each do |call|
        expect(dispatcher.dispatch(**call)).to equal(answer)
        expect(dispatcher.resolve(**call)).to equal(answer)
      end

      sites.each do |site|
        expect(dispatcher).to have_received(:dispatch_site).with(site).once
        expect(dispatcher).to have_received(:resolve_site)
          .with(site, plugin_typed_sink: nil, skip_project_patched: false).once
      end
    end

    it "dispatch_site hands the site itself to resolve_site, with neither flag, and answers its answer" do
      site = site_for(**keywords)
      allow(dispatcher).to receive_messages(resolve_site: answer, record_transitive_void_origin: nil)
      allow(context_class).to receive(:build).and_call_original

      expect(dispatcher.dispatch_site(site)).to equal(answer)
      expect(dispatcher).to have_received(:resolve_site).with(equal(site)).once
      expect(context_class).not_to have_received(:build)
    end
  end

  describe "the records dispatch_site makes after the ladder" do
    def dispatch_events(&)
      Rigor::Inference::FlowTracer.record(&).select { |event| event.kind == :dispatch }
    end

    it "asks for the transitive-void record with the site's receiver, selector, call node and scope, answer or not" do
      scope = Rigor::Scope.empty(environment: environment)
      allow(dispatcher).to receive(:record_transitive_void_origin).and_call_original

      answered = site_for(receiver_type: one, method_name: :+, arg_types: [two], call_node: call_node, scope: scope)
      declined = site_for(receiver_type: comb.top, method_name: :zz, arg_types: [], call_node: call_node, scope: scope)
      expect(dispatcher.dispatch_site(answered)).to eq(comb.constant_of(3))
      expect(dispatcher.dispatch_site(declined)).to be_nil

      expect(dispatcher).to have_received(:record_transitive_void_origin).with(one, :+, call_node, scope).once
      expect(dispatcher).to have_received(:record_transitive_void_origin).with(comb.top, :zz, call_node, scope).once
    end

    it "records the dispatch on an active trace: the site's call, its answer and the call node's location" do
      location = call_node.location
      answered = site_for(receiver_type: one, method_name: :+, arg_types: [two], call_node: call_node)
      declined = site_for(receiver_type: comb.top, method_name: :zz, arg_types: [string])

      events = dispatch_events do
        dispatcher.dispatch_site(answered)
        dispatcher.dispatch_site(declined)
      end

      expect(events.map(&:data)).to eq(
        [{ receiver: "1", method: "+", args: ["2"], type: "3", resolved: true },
         { receiver: "top", method: "zz", args: ["String"], type: nil, resolved: false }]
      )
      expect(events.first.location).to include(start_offset: location.start_offset, end_offset: location.end_offset)
      expect(events.last.location).to be_nil
    end

    it "asks nothing of the tracer outside a trace" do
      allow(Rigor::Inference::FlowTracer).to receive(:dispatch)

      dispatcher.dispatch_site(site_for(receiver_type: one, method_name: :+, arg_types: [two]))

      expect(Rigor::Inference::FlowTracer).not_to have_received(:dispatch)
    end

    # `resolve` is the ladder for a tier that dispatches again: the records are the outer call's, made once.
    it "are not made by resolve or resolve_site, which a re-entry calls" do
      keywords = { receiver_type: one, method_name: :+, arg_types: [two], call_node: call_node,
                   scope: Rigor::Scope.empty(environment: environment) }
      allow(dispatcher).to receive(:record_transitive_void_origin).and_call_original

      events = dispatch_events do
        dispatcher.resolve(**keywords)
        dispatcher.resolve_site(site_for(**keywords))
      end

      expect(events).to be_empty
      expect(dispatcher).not_to have_received(:record_transitive_void_origin)
      expect(dispatch_events { dispatcher.dispatch(**keywords) }.size).to eq(1)
      expect(dispatcher).to have_received(:record_transitive_void_origin).once
    end
  end

  describe "resolve_site, the one place the guard, the split and the order are written" do
    def optional_count = Rigor::Inference::MethodDispatcher::OptionalCount
    def method_folding = Rigor::Inference::MethodDispatcher::MethodFolding

    before do
      allow(optional_count).to receive(:split).and_call_original
      allow(method_folding).to receive(:try_backward).and_call_original
    end

    it "answers nil for a site with no receiver type, ahead of the split and of every tier" do
      keywords = { method_name: :min, arg_types: [nil_constant], environment: environment }

      expect(dispatcher.resolve_site(site_for(receiver_type: nil, **keywords))).to be_nil
      expect(optional_count).not_to have_received(:split)
      expect(method_folding).not_to have_received(:try_backward)

      # The same site with a receiver is split and answered, so the nil above is the guard's.
      expect(dispatcher.resolve_site(site_for(receiver_type: pair, **keywords))).to eq(one)
      expect(optional_count).to have_received(:split).at_least(:once)
    end

    it "is reached once by each entry, which builds no second context: the split and the ladder run once a call" do
      keywords = { receiver_type: one, method_name: :+, arg_types: [two] }
      site = site_for(**keywords)
      allow(dispatcher).to receive(:resolve_site).and_call_original
      allow(context_class).to receive(:build).and_call_original

      dispatcher.dispatch(**keywords)
      dispatcher.resolve(**keywords)
      expect(context_class).to have_received(:build).twice
      dispatcher.dispatch_site(site)
      dispatcher.resolve_site(site)

      expect(context_class).to have_received(:build).twice
      expect(dispatcher).to have_received(:resolve_site).exactly(4).times
      expect(optional_count).to have_received(:split).exactly(4).times
      expect(method_folding).to have_received(:try_backward).exactly(4).times
      expect(method_folding).to have_received(:try_backward).with(equal(site)).twice
    end

    it "asks the split with the site's receiver, selector and arguments, and whether it has a block" do
      block = comb.nominal_of("Proc")

      dispatcher.resolve_site(site_for(receiver_type: one, method_name: :+, arg_types: [two]))
      dispatcher.resolve_site(site_for(receiver_type: one, method_name: :+, arg_types: [two], block_type: block))

      expect(optional_count).to have_received(:split).with(one, :+, [two], block: false).once
      expect(optional_count).to have_received(:split).with(one, :+, [two], block: true).once
    end

    it "dispatches each part of an optional count through resolve, with the site's other fields and both flags" do
      asked = []
      answers = [string, symbol]
      allow(dispatcher).to receive(:resolve) { |**keywords| asked << keywords and answers.shift }
      sink = []
      fields = { block_type: comb.nominal_of("Proc"), environment: instance_double(Rigor::Environment),
                 call_node: call_node, scope: instance_double(Rigor::Scope) }
      site = cc(receiver: pair, method_name: :min_by, args: [comb.union(nil_constant, two)], **fields)

      answer = dispatcher.resolve_site(site, plugin_typed_sink: sink, skip_project_patched: true)

      common = { receiver_type: pair, method_name: :min_by, **fields, skip_project_patched: true }
      expect(asked.map { |keywords| keywords.except(:plugin_typed_sink) })
        .to eq([{ arg_types: [two], **common }, { arg_types: [], **common }])
      expect(asked.map { |keywords| keywords[:plugin_typed_sink] }).to all(equal(sink))
      expect(answer).to eq(comb.union(symbol, string))
      expect(method_folding).not_to have_received(:try_backward)
    end
  end

  describe "allocations" do
    # The counter is the process's, so the least of three windows is the calls' own cost even when another thread
    # allocates during one of them.
    def allocated
      Array.new(3) do
        # Reading the counter may itself allocate; an empty window measures that floor.
        before = GC.stat(:total_allocated_objects)
        floor = GC.stat(:total_allocated_objects) - before
        before = GC.stat(:total_allocated_objects)
        yield
        GC.stat(:total_allocated_objects) - before - floor
      end.min
    end

    # `top` names no class, so every tier declines it; whatever the tiers allocate on the way is the same for all
    # four entries, and the differences below are the entries' own.
    it "costs a caller that holds the site nothing: the keyword entries allocate the context and nothing else" do
      entries = dispatcher
      top = comb.top
      none = [].freeze
      site = cc(receiver: top, method_name: :zz, args: none)
      calls = {
        dispatch: -> { 100.times { entries.dispatch(receiver_type: top, method_name: :zz, arg_types: none) } },
        dispatch_site: -> { 100.times { entries.dispatch_site(site) } },
        resolve: -> { 100.times { entries.resolve(receiver_type: top, method_name: :zz, arg_types: none) } },
        resolve_site: -> { 100.times { entries.resolve_site(site) } }
      }
      calls.each_value(&:call)
      cost = calls.transform_values { |call| allocated(&call) }

      expect(cost[:dispatch] - cost[:dispatch_site]).to eq(100)
      expect(cost[:resolve] - cost[:resolve_site]).to eq(100)
      expect(cost[:dispatch_site]).to eq(cost[:resolve_site])
    end
  end
end
