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

  # ADR-116 WD12 — a site is `CallContext.build`'s for the seven fields of a call. `self_type_override` and
  # `public_only` belong to a tier, which sets them on a context it derives for the RBS-backed tier, the one
  # reader, and nothing outside the dispatcher's directory sets either. The dispatcher does not check a site for
  # them; the last two examples are why a site must not set one: it would not be answered as a call with that
  # property.
  #
  # ADR-132 WD3, not landed, makes visibility a field of the call. The slice that lets a site set `public_only`
  # threads it through the re-entries and the fallback, and changes these examples with the rule.
  #
  # The first two examples read the code, and know a context by how it is spelled: the `CallContext` class, a
  # context built or derived in place, a local assigned one in the same file, and anything named `context` or
  # `site` (`base_context`, `@site`). Another value with a field of the same name is not one: ADR-132's
  # `Invocation` has a `public_only` of its own. A context held under another name is not seen.
  describe "a site's two other fields" do
    def root = File.expand_path("../../../..", __dir__)
    def dispatcher_directory = "lib/rigor/inference/method_dispatcher/"
    def other_fields = %i[self_type_override public_only]
    def integer = comb.nominal_of("Integer")

    # The two fields `call` sets on a context: as keywords of `CallContext.build` or of a context's `with`, or
    # positionally through `CallContext.new`, which sets every field.
    def fields_set_by(call, held)
      return [] unless context?(call.receiver, held)
      return other_fields if call.name == :new
      return [] unless %i[build with].include?(call.name)

      keywords = (call.arguments&.arguments || []).grep(Prism::KeywordHashNode).flat_map(&:elements)
      keywords.grep(Prism::AssocNode).map { |pair| pair.key.slice.delete_suffix(":").to_sym } & other_fields
    end

    # The two fields `call` reads off a context: a call of the field's reader on one.
    def fields_read_by(call, held)
      call.arguments.nil? && context?(call.receiver, held) ? [call.name] & other_fields : []
    end

    # Whether `node` is a context, or the class of one, as far as its spelling says. `held` is the locals the
    # file assigns a context to.
    def context?(node, held)
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode then node.slice.end_with?("CallContext")
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
        held.include?(node.name) || context_name?(node.name)
      when Prism::CallNode
        made = %i[build new with].include?(node.name)
        made ? context?(node.receiver, held) : node.receiver.nil? && context_name?(node.name)
      else false
      end
    end

    def context_name?(name) = name.to_s.match?(/(?:\A|_|@)(?:context|site)\z/)

    def each_node(source)
      pending = [Prism.parse(source).value]
      while (node = pending.shift)
        yield node
        pending.concat(node.compact_child_nodes)
      end
    end

    # The fields the calls of `source` set (`:set`) or read (`:read`) on a context.
    def fields_in(source, use)
      held = []
      each_node(source) do |node|
        held << node.name if node.is_a?(Prism::LocalVariableWriteNode) && context?(node.value, held)
      end
      found = []
      each_node(source) do |node|
        next unless node.is_a?(Prism::CallNode)

        found.concat(use == :set ? fields_set_by(node, held) : fields_read_by(node, held))
      end
      found.uniq
    end

    # `path => fields` for every file of the engine, the plugins and the examples that sets, or reads, one.
    def files(use)
      paths = Dir.glob(%w[lib/**/*.rb plugins/*/lib/**/*.rb examples/*/lib/**/*.rb], base: root).sort
      paths.filter_map do |path|
        source = File.read(File.join(root, path))
        fields = source.match?(/self_type_override|public_only|CallContext/) ? fields_in(source, use) : []
        [path, fields] unless fields.empty?
      end.to_h
    end

    def answer(receiver, method_name, **fields)
      dispatcher.dispatch_site(
        cc(receiver: receiver, method_name: method_name, args: [], environment: environment, **fields)
      )
    end

    it "are set by a dispatcher tier and by nothing outside the dispatcher's directory" do
      inside, outside = files(:set).partition { |path, _fields| path.start_with?(dispatcher_directory) }.map(&:to_h)

      expect(outside).to eq({})
      expect(inside).to include("#{dispatcher_directory}user_class_fallback.rb" => other_fields)
      expect(fields_in("site.with(public_only: true); CallContext.new(a, b); Other.build(public_only: 1)", :set))
        .to eq(%i[public_only self_type_override])
      expect(fields_in("held = MethodDispatcher::CallContext.build(receiver: r); held.with(public_only: true)", :set))
        .to eq(%i[public_only])
    end

    it "are read by the RBS-backed tier and by no other" do
      expect(files(:read)).to eq("#{dispatcher_directory}rbs_dispatch.rb" => other_fields)
      expect(fields_in("context.public_only; @site.self_type_override; public_only = 1; public_only", :read))
        .to eq(other_fields.reverse)
    end

    it "are a context's: a field of the same name on another value is neither set nor read" do
      invocation = <<~RUBY
        Invocation = Data.define(:node, :public_only)
        inv = Invocation.new(node, true)
        inv.public_only
        inv.with(public_only: true)
        ReflectiveCall.build(node, public_only: inv.public_only)
      RUBY

      expect(fields_in(invocation, :set)).to eq([])
      expect(fields_in(invocation, :read)).to eq([])
      expect(fields_in(invocation.gsub("inv", "site"), :read)).to eq(%i[public_only])
    end

    it "are taken by neither keyword entry, so a call the dispatcher dispatches again is built without them" do
      call = { receiver_type: string, method_name: :dup, arg_types: [], environment: environment }

      expect { dispatcher.dispatch(**call, public_only: true) }.to raise_error(ArgumentError, /public_only/)
      expect { dispatcher.resolve(**call, self_type_override: integer) }
        .to raise_error(ArgumentError, /self_type_override/)
      expect(dispatcher.dispatch(**call)).to eq(string)
    end

    it "would make a site public-only for the receiver's own RBS lookup, not through a re-entry or the fallback" do
      expect(answer(string, :puts)).to eq(nil_constant)
      expect(answer(string, :puts, public_only: true)).to be_nil
      expect(answer(comb.union(string, integer), :puts, public_only: true)).to eq(nil_constant)
      expect(answer(rbs_less, :puts, public_only: true)).to eq(nil_constant)
    end

    it "would bind `self` for the RBS lookup alone, where the fallback binds the receiver it was given" do
      expect(answer(string, :dup)).to eq(string)
      expect(answer(string, :dup, self_type_override: integer)).to eq(integer)
      expect(answer(rbs_less, :dup, self_type_override: integer)).to eq(rbs_less)
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
