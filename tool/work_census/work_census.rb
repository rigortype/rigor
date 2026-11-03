# frozen_string_literal: true

# Work-multiplier census for `rigor check`. Run from the TARGET's directory:
#   RIGOR_LIB=<rigor>/lib MODE=phases|census bundle exec ruby work_census.rb <check args...>
# MODE=phases: exclusive thread-CPU per engine phase (light hooks).
# MODE=census: per-node / per-(node,scope) call counts for type_of / evaluate, callee-body evals.

$LOAD_PATH.unshift(ENV.fetch('RIGOR_LIB'))
require 'rigor/cli'
require 'rigor'
require 'json'
require 'set'

module WC
  MODE = ENV.fetch('MODE', 'phases')
  CENSUS = MODE == 'census'
  EXCL = Hash.new(0.0)
  FILE_ROWS = []
  INCL_COUNT = Hash.new(0)
  STACK = []
  @last = nil

  def self.cpu = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)

  def self.phase(name)
    now = cpu
    EXCL[STACK.last || 'outside'] += now - @last if @last
    @last = now
    STACK.push(name)
    INCL_COUNT[name] += 1
    begin
      yield
    ensure
      now = cpu
      EXCL[STACK.last] += now - @last
      @last = now
      STACK.pop
    end
  end

  def self.top = STACK.last || 'outside'

  # ---- census state (per file, folded at file end) ----
  G = Hash.new(0)
  BY_CLASS_EXCESS = Hash.new(0)       # node class => sum(calls-1) for type_of
  BY_CLASS_SAME_SCOPE = Hash.new(0)   # node class => sum over (node,scope) of (m-1)
  EVAL_BY_CLASS_EXCESS = Hash.new(0)
  HIST = Hash.new(0)                  # type_of calls-per-node histogram (bucketed)
  EVAL_HIST = Hash.new(0)
  CALLS_BY_PHASE = Hash.new(0)
  ROOT_CALLS_BY_PHASE = Hash.new(0)
  SCOPES_BY_PHASE = Hash.new(0)
  UNION_BY_PHASE = Hash.new(0)
  CALLEE_BY_PHASE = Hash.new(0)
  CALLEE_PER_DEF = Hash.new(0)        # "path:line name" => body evals (whole run)
  @t_nodes = {}.compare_by_identity
  @e_nodes = {}.compare_by_identity
  @depth = 0

  class << self
    attr_accessor :depth
  end

  def self.bucket(n)
    case n
    when 1 then '1'
    when 2 then '2'
    when 3 then '3'
    when 4..7 then '4-7'
    when 8..15 then '8-15'
    when 16..63 then '16-63'
    when 64..255 then '64-255'
    else '256+'
    end
  end

  def self.note_type_of(node, scope)
    G[:type_of_calls] += 1
    CALLS_BY_PHASE[top] += 1
    if @depth.zero?
      G[:type_of_root_calls] += 1
      ROOT_CALLS_BY_PHASE[top] += 1
    end
    per = (@t_nodes[node] ||= {}.compare_by_identity)
    per[scope] = (per[scope] || 0) + 1
  end

  def self.note_evaluate(node, scope)
    G[:evaluate_calls] += 1
    per = (@e_nodes[node] ||= {}.compare_by_identity)
    per[scope] = (per[scope] || 0) + 1
  end

  DEPTH_T = Hash.new(0)
  DEPTH_TN = Hash.new(0)
  DEPTH_E = Hash.new(0)
  DEPTH_EN = Hash.new(0)
  DEPTH_ALL = Hash.new(0)
  @depth_map = {}.compare_by_identity
  # per def: { key => result description }, plus path counters
  DEF_KEYS = {}.compare_by_identity
  MEMO = Hash.new(0)
  @pending = nil

  class << self
    attr_accessor :pending, :next_callee_phase, :current_nodes, :callee_tag
  end

  def self.build_depth_map(root)
    n = 0
    stack = [[root, 0]]
    while (pair = stack.pop)
      x, d = pair
      n += 1
      @depth_map[x] = d
      DEPTH_ALL[d] += 1
      cd = x.is_a?(Prism::BlockNode) || x.is_a?(Prism::LambdaNode) ? d + 1 : d
      x.rigor_each_child { |c| stack << [c, cd] }
    end
    n
  end

  def self.fold_file
    @t_nodes.each do |node, per|
      total = per.values.sum
      if (d = @depth_map[node])
        DEPTH_T[d] += total
        DEPTH_TN[d] += 1
      else
        G[:type_of_foreign_calls] += total
      end
      G[:typed_nodes] += 1
      G[:typed_pairs] += per.size
      HIST[bucket(total)] += 1
      BY_CLASS_EXCESS[node.class.name.sub('Prism::', '')] += total - 1
      same = total - per.size
      G[:type_of_same_scope_repeats] += same
      BY_CLASS_SAME_SCOPE[node.class.name.sub('Prism::', '')] += same
    end
    @e_nodes.each do |node, per|
      total = per.values.sum
      if (d = @depth_map[node])
        DEPTH_E[d] += total
        DEPTH_EN[d] += 1
      end
      G[:evaluated_nodes] += 1
      G[:evaluated_pairs] += per.size
      EVAL_HIST[bucket(total)] += 1
      EVAL_BY_CLASS_EXCESS[node.class.name.sub('Prism::', '')] += total - 1
      G[:evaluate_same_scope_repeats] += total - per.size
    end
    @t_nodes = {}.compare_by_identity
    @e_nodes = {}.compare_by_identity
    @depth_map = {}.compare_by_identity
  end

  def self.count_nodes(root)
    n = 0
    stack = [root]
    while (x = stack.pop)
      n += 1
      x.rigor_each_child { |c| stack << c }
    end
    n
  end
end

Rigor::Analysis::Runner.prepend(Module.new do
  def ensure_project_discovery(*a, **k) = WC.phase('discovery') { super }
  def run_project_pre_passes(*a, **k) = WC.phase('pre_passes') { super }
  def seed_parameter_inference(*a, **k) = WC.phase('param_inference') { super }

  def parse_source(*a, **k)
    r = WC.phase('parse') { super }
    if r.respond_to?(:value) && r.value
      if WC::CENSUS
        n = WC.build_depth_map(r.value)
        WC::G[:ast_nodes] += n
        WC::G[:files] += 1
      else
        n = WC.count_nodes(r.value)
      end
      WC.current_nodes = n
    end
    r
  end

  def analyze_file_body(path, *a, **k)
    t0 = WC.cpu
    c0 = WC::CALLEE_BY_PHASE.values.sum
    WC.current_nodes = nil
    WC.phase('file') { super }
  ensure
    WC::FILE_ROWS << [path, WC.current_nodes, (WC.cpu - t0).round(4), WC::CALLEE_BY_PHASE.values.sum - c0]
    WC.fold_file if WC::CENSUS
  end

  def rule_and_plugin_diagnostics(*a, **k) = WC.phase('rules') { super }
  def node_rule_results_by_plugin(*a, **k) = WC.phase('rules:node_walk') { super }
end)

Rigor::Analysis::CheckRules.singleton_class.prepend(Module.new do
  def diagnose(*a, **k) = WC.phase('rules:diagnose') { super }
  def build_node_collectors(*a, **k) = WC.phase('rules:collectors') { super }
end)

Rigor::Inference::ScopeIndexer.singleton_class.prepend(Module.new do
  def index(*a, **k) = WC.phase('index') { super }
  def build_declaration_artifacts(*a, **k) = WC.phase('index:decls') { super }
  def build_class_ivar_index(*a, **k) = WC.phase('index:ivar') { super }
  def collect_literal_receiver_mutations(*a, **k) = WC.phase('index:mutations') { super }
  def build_class_cvar_index(*a, **k) = WC.phase('index:cvars') { super }
  def seed_program_globals(*a, **k) = WC.phase('index:globals') { super }
  def build_in_source_constants(*a, **k) = WC.phase('index:consts') { super }
  def seed_constant_tables(*a, **k) = WC.phase('index:consts') { super }
  def seed_published_constant_ivars(*a, **k) = WC.phase('index:consts') { super }
  def seed_discovered_methods(*a, **k) = WC.phase('index:methods') { super }
  def merge_project_method_indexes(*a, **k) = WC.phase('index:methods') { super }
  def seed_struct_fold_safe(*a, **k) = WC.phase('index:struct') { super }

  def propagate(*a, **k)
    return super if WC.top == 'index:propagate' || WC.top.start_with?('index:eval')

    WC.phase('index:propagate') { super }
  end

  def recording_evaluator(*a, **k)
    inner = super
    lambda do |*args|
      WC.phase('index:eval') { inner.call(*args) }
    end
  end
end)

Rigor::Inference::ExpressionTyper.prepend(Module.new do
  def compute_user_method_return(def_node, *a, **k)
    WC::CALLEE_BY_PHASE[WC.top] += 1
    if WC::CENSUS
      loc = def_node.location
      WC::CALLEE_PER_DEF["#{loc.start_line}:#{def_node.name}:#{def_node.object_id}"] += 1
    end
    name = WC.next_callee_phase || 'callee_body'
    WC.next_callee_phase = nil
    WC.phase(name) { super }
  end
end)

if ENV['MEMO'] == '1'
  # PROTOTYPE (measurement only): memoise ExpressionTyper#type_of on (scope identity, node identity),
  # bypassed while a threaded operand table or a key-presence guard is active. Cleared per file.
  module WCMemo
    @table = {}.compare_by_identity
    @stats = Hash.new(0)
    class << self
      attr_reader :stats, :table

      def clear! = (@table = {}.compare_by_identity)
    end
  end
  Rigor::Analysis::Runner.prepend(Module.new do
    def analyze_file_body(*a, **k)
      super
    ensure
      WCMemo.clear!
    end
  end)
  Rigor::Inference::ExpressionTyper.prepend(Module.new do
    def type_of(node)
      if @operand_types || Rigor::Inference::KeyPresenceGuard.active? || !node.is_a?(Prism::Node)
        WCMemo.stats[:bypass] += 1
        return super
      end

      per = (WCMemo.table[scope] ||= {}.compare_by_identity)
      if (hit = per[node])
        WCMemo.stats[:hit] += 1
        return hit
      end
      WCMemo.stats[:miss] += 1
      per[node] = super
    end
  end)
  at_exit { warn "memo stats: #{WCMemo.stats}" }
end

require_relative 'memo3' if ENV['MEMO'] == '3' || ENV['COUNT3'] == '1'

if WC::CENSUS
  Rigor::Inference::ExpressionTyper.prepend(Module.new do
    def type_of(node)
      WC.note_type_of(node, scope)
      WC.depth += 1
      begin
        super
      ensure
        WC.depth -= 1
      end
    end
  end)

  Rigor::Inference::StatementEvaluator.prepend(Module.new do
    def evaluate(node)
      WC.note_evaluate(node, @scope)
      super
    end
  end)

  Rigor::Inference::ExpressionTyper.prepend(Module.new do
    def consult_and_store_return_memo(def_node, *rest)
      WC::MEMO[:consults] += 1
      before = WC::MEMO[:computes]
      WC.pending = def_node
      r = super
      WC.pending = nil
      WC::MEMO[:hits] += 1 if WC::MEMO[:computes] == before
      r
    end

    def compute_user_method_return(def_node, body_scope, stack, summaries, receiver, arg_types, plain_signature)
      WC::MEMO[:computes] += 1
      if WC.pending.equal?(def_node)
        WC::MEMO[:compute_via_miss] += 1
      else
        WC::MEMO[:compute_refused_or_uncached] += 1
      end
      via_miss = WC.pending.equal?(def_node)
      WC.pending = nil
      key = [receiver.describe(:short), arg_types.map { |t| t.describe(:short) }]
      per = (WC::DEF_KEYS[def_node] ||= Hash.new { |h, k| h[k] = [0, nil] })
      cls =
        if per.empty? then 'first'
        elsif per.key?(key) then via_miss ? 'seen_key_unstored' : 'seen_key_refused'
        else via_miss ? 'new_key' : 'new_key_refused'
        end
      WC::MEMO["class_#{cls}"] += 1
      WC.next_callee_phase = "callee_body:#{cls}:#{WC.callee_tag}"
      result = super
      slot = per[key]
      slot[0] += 1
      slot[1] = result ? result.describe(:short) : 'nil'
      result
    end
  end)

  module WCRead
    FRAMES = []
    STATS = Hash.new(0)
    KEYS = {}.compare_by_identity   # def_node => { collapsed_key => result }
    def self.param_names(def_node)
      ps = def_node.parameters
      return [[], true] if ps.nil?
      simple = ps.rest.nil? && ps.posts.empty? && ps.keywords.empty? && ps.keyword_rest.nil?
      names = (ps.requireds + ps.optionals).map { |n| n.respond_to?(:name) ? n.name : nil }
      extra = []
      extra << ps.rest.name if ps.rest.respond_to?(:name) && ps.rest.name
      ps.posts.each { |n| extra << n.name if n.respond_to?(:name) }
      ps.keywords.each { |n| extra << n.name if n.respond_to?(:name) }
      extra << ps.keyword_rest.name if ps.keyword_rest.respond_to?(:name) && ps.keyword_rest.name
      [names + extra, simple && names.none?(&:nil?)]
    end
  end
  Rigor::Scope.prepend(Module.new do
    def local(name)
      f = WCRead::FRAMES.last
      f[:read] << name.to_sym if f && f[:params].include?(name.to_sym)
      super
    end
    def locals
      f = WCRead::FRAMES.last
      f[:bulk] = true if f
      super
    end
  end)
  Rigor::Inference::ExpressionTyper.prepend(Module.new do
    def compute_user_method_return(def_node, body_scope, stack, summaries, receiver, arg_types, plain_signature)
      names, simple = WCRead.param_names(def_node)
      in_cycle = stack.any? { |f| (f[0].is_a?(Array) ? f[0] : f) == plain_signature }
      if in_cycle
        WC.callee_tag = 'cycle'
        return super
      end
      WC.callee_tag =
        if arg_types.empty? then 'noargs'
        elsif arg_types.all? { |t| t.equal?(Rigor::Type::Combinator.untyped) || t.describe(:short) == 'Dynamic[top]' } then 'alldyn'
        else 'typed'
        end
      frame = { params: names.compact.to_set, read: Set.new, bulk: false }
      WCRead::FRAMES.push(frame)
      begin
        result = super
      ensure
        WCRead::FRAMES.pop
      end
      rdesc = result ? result.describe(:short) : 'nil'
      st = WCRead::STATS
      st[:evals] += 1
      st[:evals_with_params] += 1 unless names.empty?
      unread = frame[:params] - frame[:read]
      st[:evals_all_params_unread] += 1 if !names.empty? && unread.size == frame[:params].size
      st[:evals_some_param_unread] += 1 unless unread.empty?
      st[:evals_bulk_locals] += 1 if frame[:bulk]
      args = arg_types.map { |t| t.describe(:short) }
      ckey =
        if names.empty? then [receiver.describe(:short)]
        elsif unread.size == frame[:params].size then [receiver.describe(:short), :all_unread]
        elsif simple then [receiver.describe(:short), names.each_with_index.map { |n, i| frame[:read].include?(n) ? args[i] : :_ }]
        else [receiver.describe(:short), args]
        end
      per = (WCRead::KEYS[def_node] ||= {})
      if per.key?(ckey)
        st[:evals_hit_under_collapsed_key] += 1
        st[:collapsed_key_result_mismatch] += 1 if per[ckey] != rdesc
      else
        per[ckey] = rdesc
      end
      result
    end
  end)
  Rigor::Scope.prepend(Module.new do
    def initialize(*a, **k)
      WC::G[:scopes_built] += 1
      WC::SCOPES_BY_PHASE[WC.top] += 1
      super
    end
  end)

  Rigor::Type::Combinator.singleton_class.prepend(Module.new do
    def union(*types)
      WC::G[:union_calls] += 1
      WC::UNION_BY_PHASE[WC.top] += 1
      super
    end
  end)
end

gc0 = GC.stat(:time)
alloc0 = GC.stat(:total_allocated_objects)
wall0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
status = WC.phase('cli') { Rigor::CLI.start(ARGV) }
wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall0

out = {
  mode: WC::MODE,
  status: status,
  wall_s: wall.round(2),
  gc_s: ((GC.stat(:time) - gc0) / 1000.0).round(2),
  allocations: GC.stat(:total_allocated_objects) - alloc0,
  excl_cpu_s: WC::EXCL.transform_values { |v| v.round(2) }.sort_by { -_2 }.to_h,
  phase_entries: WC::INCL_COUNT,
  callee_body_evals_by_parent_phase: WC::CALLEE_BY_PHASE
}
if WC::CENSUS
  out[:global] = WC::G
  out[:type_of_hist] = WC::HIST
  out[:evaluate_hist] = WC::EVAL_HIST
  out[:type_of_calls_by_phase] = WC::CALLS_BY_PHASE
  out[:type_of_root_calls_by_phase] = WC::ROOT_CALLS_BY_PHASE
  out[:scopes_by_phase] = WC::SCOPES_BY_PHASE
  out[:union_by_phase] = WC::UNION_BY_PHASE
  out[:type_of_excess_by_class] = WC::BY_CLASS_EXCESS.sort_by { -_2 }.first(25).to_h
  out[:type_of_same_scope_by_class] = WC::BY_CLASS_SAME_SCOPE.sort_by { -_2 }.first(25).to_h
  out[:evaluate_excess_by_class] = WC::EVAL_BY_CLASS_EXCESS.sort_by { -_2 }.first(20).to_h
  out[:depth] = WC::DEPTH_ALL.keys.sort.to_h do |d|
    [d, { nodes: WC::DEPTH_ALL[d], typed_nodes: WC::DEPTH_TN[d], type_of_calls: WC::DEPTH_T[d],
          type_of_per_typed_node: (WC::DEPTH_T[d].to_f / [WC::DEPTH_TN[d], 1].max).round(2),
          evaluate_calls: WC::DEPTH_E[d],
          evaluate_per_evaluated_node: (WC::DEPTH_E[d].to_f / [WC::DEPTH_EN[d], 1].max).round(2) }]
  end
  keys_total = 0
  results_total = 0
  evals_total = 0
  same_result_defs = 0
  same_result_evals = 0
  multi_key_defs = 0
  repeat_same_key_evals = 0
  WC::DEF_KEYS.each_value do |per|
    keys = per.size
    res = per.values.map { |s| s[1] }.uniq.size
    ev = per.values.sum { |s| s[0] }
    keys_total += keys
    results_total += res
    evals_total += ev
    repeat_same_key_evals += ev - keys
    next unless keys > 1

    multi_key_defs += 1
    if res == 1
      same_result_defs += 1
      same_result_evals += ev - 1
    end
  end
  out[:memo] = WC::MEMO.merge(
    defs: WC::DEF_KEYS.size, distinct_keys: keys_total, distinct_results: results_total, body_evals: evals_total,
    evals_repeating_a_seen_key: repeat_same_key_evals,
    multi_key_defs: multi_key_defs, multi_key_defs_with_one_result: same_result_defs,
    evals_collapsible_if_key_ignored_args: same_result_evals,
    evals_beyond_distinct_results: evals_total - results_total
  )
  recv_groups = 0
  recv_collapsible = 0
  recv_multi = 0
  WC::DEF_KEYS.each_value do |per|
    by_args = Hash.new { |h, k| h[k] = [] }
    per.each { |(recv, args), (cnt, res)| by_args[args] << [recv, cnt, res] }
    by_args.each_value do |rows|
      recv_groups += 1
      next if rows.size < 2
      recv_multi += 1
      recv_collapsible += rows.sum { |r| r[1] } - 1 if rows.map { |r| r[2] }.uniq.size == 1
    end
  end
  out[:receiver_collapse] = { arg_groups: recv_groups, groups_with_multiple_receivers: recv_multi,
                              evals_collapsible_if_receiver_dropped: recv_collapsible }
  per_def = WC::CALLEE_PER_DEF.values
  out[:callee] = {
    distinct_defs: per_def.size,
    body_evals: per_def.sum,
    max: per_def.max,
    top: WC::CALLEE_PER_DEF.sort_by { -_2 }.first(15).to_h
  }
end
out[:files] = WC::FILE_ROWS
out[:read_collapse] = WCRead::STATS if defined?(WCRead)
out[:memo3] = WC3.report if defined?(WC3)
path = ENV.fetch('OUT', 'census.json')
File.write(path, JSON.pretty_generate(out))
warn "wrote #{path}"
