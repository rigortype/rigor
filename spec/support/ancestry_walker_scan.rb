# frozen_string_literal: true

require "prism"

# The Prism scan behind `spec/rigor/scope/ancestry_walker_detection_spec.rb`: every method under `lib/` and
# `plugins/*/lib/` that walks the discovery tables' ancestry edges itself rather than reading
# `Scope::ResolutionChain`. See the spec's header for the rule and for what the scan cannot see.
module AncestryWalkerScan
  # The ten ancestry readers: `Scope`'s keyed readers and the raw tables behind them (a `DiscoveryIndex` member
  # or its `Scope` pass-through, which share names), and the two that hand out a class's direct ancestors one
  # step at a time — `Scope#enqueue_ancestors` and `ResolutionChain.direct_ancestors` — whose loop is a
  # breadth-first walk over the same edges.
  READERS = %i[
    includes_of prepends_of superclass_of singleton_extends_of
    discovered_includes discovered_prepends discovered_superclasses discovered_extends
    enqueue_ancestors direct_ancestors
  ].freeze

  # A reader whose result only answers membership or emptiness — `discovered_superclasses.key?(name)` asks
  # whether a name is a project class, `includes_of(name).empty?` whether it mixes anything in — reads no
  # edge, so it does not count.
  MEMBERSHIP = %i[key? has_key? include? member? empty? any? none? size length].freeze

  # A table taken whole — merged into another (`discovered_includes.merge(per_file)`) or held in an instance
  # variable (`@project_discovered_includes = discovery.discovered_includes`) — is copied, not walked: no
  # ancestor's edge is read, so it does not count either.
  WHOLE = %i[merge merge! dup clone].freeze

  # The files allowed to walk them: the chain builder, and the per-name relevance rule that reads the closure of
  # a mark's named entry (ADR-119 WD2), which is part of the chain's own decision.
  CHAIN_BUILDERS = %w[lib/rigor/scope/resolution_chain.rb lib/rigor/scope/resolution_chain/relevance.rb].freeze
  CHAIN_BUILDER = CHAIN_BUILDERS.first

  # The files that may read what `settle`'s `unknown_for:` decision is made of — fork counts, marks, the
  # unpositioned table — or pass the option: the chain's files, and the candidate-set read that is its one caller
  # (with its singleton-side hook decline, which reads the unpositioned table's `"*"`).
  DECISION_INPUTS = /
    \.forks\b | \.skip_count\b | \.marks\b | \.unpositioned_mixins(?:\[|\.(?:dig|fetch|key\?)) | \bunknown_for:
  /x

  DECISION_READERS = (CHAIN_BUILDERS + %w[
    lib/rigor/inference/definer_resolution.rb lib/rigor/inference/singleton_hook_decline.rb
  ]).freeze

  Finding = Data.define(:key, :reasons)

  # One method's reads, gathered by {MethodVisitor}.
  class MethodFacts
    attr_reader :name, :readers, :loop_reads, :calls, :loop_calls

    def initialize(name)
      @name = name
      @readers = Set.new
      @loop_reads = Set.new
      @calls = Set.new
      @loop_calls = Set.new
    end
  end

  # Walks one file, one {MethodFacts} per `def`. A block, `while`, `until` or `for` body counts as a loop: a
  # block is where `each`, `until queue.empty?`'s cousin `loop do`, and every Enumerable walk put their body.
  class MethodVisitor < Prism::Visitor
    attr_reader :methods

    def initialize
      super
      @methods = []
      @current = nil
      @loop_depth = 0
      @aliases = nil
      @edgeless = {}.compare_by_identity
    end

    def visit_def_node(node)
      outer = [@current, @loop_depth, @aliases]
      @current = MethodFacts.new(node.receiver ? "self.#{node.name}" : node.name.to_s)
      @methods << @current
      @loop_depth = 0
      @aliases = Set.new
      super
    ensure
      @current, @loop_depth, @aliases = outer
    end

    def visit_block_node(node) = in_loop { super }
    def visit_lambda_node(node) = in_loop { super }
    def visit_while_node(node) = in_loop { super }
    def visit_until_node(node) = in_loop { super }
    def visit_for_node(node) = in_loop { super }

    # A local assigned from a reader (`supers = scope.discovered_superclasses`) is the table under another
    # name; reading it inside a loop is a loop read.
    def visit_local_variable_write_node(node)
      value = node.value
      @aliases << node.name if @current && value.is_a?(Prism::CallNode) && READERS.include?(value.name)
      super
    end

    def visit_instance_variable_write_node(node)
      value = node.value
      @edgeless[value] = true if @current && value.is_a?(Prism::CallNode) && READERS.include?(value.name)
      super
    end

    def visit_local_variable_read_node(node)
      if @current && @loop_depth.positive? && @aliases.include?(node.name) && !@edgeless.key?(node)
        @current.loop_reads << :"#{node.name} (alias)"
      end
      super
    end

    def visit_call_node(node)
      if @current
        @edgeless[node.receiver] = true if node.receiver && edgeless_use?(node)
        record_call(node) unless @edgeless.key?(node)
      end
      super
    end

    private

    def edgeless_use?(node) = (MEMBERSHIP.include?(node.name) && node.block.nil?) || WHOLE.include?(node.name)

    def in_loop
      @loop_depth += 1
      yield
    ensure
      @loop_depth -= 1
    end

    def record_call(node)
      if READERS.include?(node.name)
        @current.readers << node.name
        @current.loop_reads << node.name if @loop_depth.positive?
      elsif node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
        @current.calls << node.name.to_s
        @current.loop_calls << node.name.to_s if @loop_depth.positive?
      end
    end
  end

  module_function

  def files(root)
    Dir.glob(%w[lib/**/*.rb plugins/*/lib/**/*.rb], base: root).sort - CHAIN_BUILDERS
  end

  # `{ "path#method" => [reason, …] }` for every walker in `files`.
  def scan(root)
    files(root).each_with_object({}) do |path, out|
      source = File.read(File.join(root, path))
      next unless READERS.any? { |reader| source.include?(reader.to_s) }

      visitor = MethodVisitor.new
      Prism.parse(source, filepath: path).value.accept(visitor)
      findings_for(path, visitor.methods).each { |finding| out[finding.key] = finding.reasons }
    end
  end

  def findings_for(path, methods)
    readers_by_name = methods.each_with_object({}) do |facts, by_name|
      (by_name[facts.name] ||= Set.new).merge(facts.readers)
    end
    recursive = recursive_names(methods)
    methods.filter_map do |facts|
      reasons = reasons_for(facts, readers_by_name, recursive)
      Finding.new(key: "#{path}##{facts.name}", reasons: reasons) unless reasons.empty?
    end
  end

  def reasons_for(facts, readers_by_name, recursive)
    readers = listing(facts.readers)
    reasons = []
    reasons << "reads #{readers}" if facts.readers.size >= 2
    reasons << "reads #{listing(facts.loop_reads)} inside a loop" unless facts.loop_reads.empty?
    looped = facts.loop_calls.reject { |name| readers_by_name.fetch(name, Set.new).empty? }
    reasons << "calls #{listing(looped)} (which read the tables) inside a loop" unless looped.empty?
    reasons << "reads #{readers} in a recursive method" if recursive.include?(facts.name) && !facts.readers.empty?
    reasons
  end

  def listing(names) = names.to_a.map(&:to_s).sort.join(", ")

  # The names of the file's methods that can reach themselves through the file's own receiverless calls —
  # directly, or through a cycle of helpers (`instance_side?` → `instance_ancestor?` → `instance_side?`).
  def recursive_names(methods)
    graph = methods.each_with_object({}) { |facts, edges| (edges[facts.name] ||= Set.new).merge(facts.calls) }
    graph.each_value { |callees| callees.select! { |callee| graph.key?(callee) } }
    graph.keys.select { |name| reaches?(graph, name, name) }.to_set
  end

  def reaches?(graph, from, target)
    seen = Set.new
    stack = graph.fetch(from).to_a
    until stack.empty?
      current = stack.pop
      return true if current == target
      next unless seen.add?(current)

      stack.concat(graph.fetch(current).to_a)
    end
    false
  end
end
