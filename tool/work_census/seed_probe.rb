# frozen_string_literal: true

# #2710 probe: could the main pass's evaluation of a def seed the return memo?
#
# Run from the target's directory:
#   RIGOR_LIB=<rigor>/lib OUT=/tmp/seed.json bundle exec ruby seed_probe.rb check --no-cache --workers=0 ...
#
# After the main pass evaluates a def (`StatementEvaluator#eval_def`), the probe re-evaluates the body the same way
# (same entry scope, same `widen_clauses:`) under a return sink and joins the returns, which is the return the main
# pass would have to record to seed the memo. Each callee compute (`compute_user_method_return`, in-cycle re-entries
# excluded) is classed by its argument shape. A compute whose arguments are all `Dynamic[top]` (or absent) and whose
# receiver is the def's own main-pass `self` is one a seed could serve; for those the probe reports whether the seed
# agrees with the compute, and whether the main pass ran before the compute did (only then is a seed available).

$LOAD_PATH.unshift(ENV.fetch("RIGOR_LIB"))
require "rigor/cli"
require "rigor"
require "json"

module SeedProbe
  MAIN = {}.compare_by_identity # def_node => [receiver description, all-Dynamic params?, result description, seq]
  CALLEE = Hash.new { |h, k| h[k] = [] }.compare_by_identity # def_node => [[receiver, shape, result, seq, cpu], ...]
  FRAMES = []
  @seq = 0
  @in_probe = false

  class << self
    attr_accessor :in_probe

    def tick = (@seq += 1)
    def cpu = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
  end

  def self.dynamic?(type) = type.equal?(Rigor::Type::Combinator.untyped) || type.describe(:short) == "Dynamic[top]"

  def self.param_names(def_node)
    ps = def_node.parameters
    return [] if ps.nil?

    nodes = ps.requireds + ps.optionals + ps.posts + ps.keywords
    nodes << ps.rest if ps.rest
    nodes << ps.keyword_rest if ps.keyword_rest
    nodes.filter_map { |n| n.respond_to?(:name) ? n.name : nil }
  end
end

Rigor::Inference::StatementEvaluator.prepend(Module.new do
  def eval_def(node)
    result = super
    return result if SeedProbe.in_probe || node.body.nil?

    SeedProbe.in_probe = true
    begin
      body_scope = build_method_entry_scope(node)
      sites = Rigor::Inference::RepeatedOrWrites.straight_line_sites(node.body, body_scope)
      body_scope = body_scope.with_repeated_or_writes(sites)
      (type, _post), returns = Rigor::Inference::StatementEvaluator.with_return_sink do
        self.class.new(scope: body_scope, class_context: @class_context, lexical_nesting: @lexical_nesting,
                       widen_clauses: @widen_clauses).evaluate(node.body)
      end
      joined = returns.empty? ? type : Rigor::Type::Combinator.union(type, *returns)
      all_dynamic = SeedProbe.param_names(node).all? do |name|
        bound = body_scope.local(name)
        bound.nil? || SeedProbe.dynamic?(bound)
      end
      SeedProbe::MAIN[node] ||= [body_scope.self_type&.describe(:short), all_dynamic, joined.describe(:short),
                                 SeedProbe.tick]
    rescue StandardError => e
      SeedProbe::MAIN[node] ||= [nil, false, "probe-error: #{e.class}", SeedProbe.tick]
    ensure
      SeedProbe.in_probe = false
    end
    result
  end
end)

Rigor::Inference::ExpressionTyper.prepend(Module.new do
  def compute_user_method_return(def_node, body_scope, stack, summaries, receiver, arg_types, plain_signature)
    in_cycle = stack.any? { |f| (f[0].is_a?(Array) ? f[0] : f) == plain_signature }
    return super if in_cycle || SeedProbe.in_probe

    frame = [SeedProbe.cpu, 0.0]
    SeedProbe::FRAMES.push(frame)
    result = nil
    begin
      result = super
    ensure
      SeedProbe::FRAMES.pop
      inclusive = SeedProbe.cpu - frame[0]
      SeedProbe::FRAMES.last[1] += inclusive if SeedProbe::FRAMES.last
      shape =
        if arg_types.empty? then :noargs
        elsif arg_types.all? { |t| SeedProbe.dynamic?(t) } then :alldyn
        else :typed
        end
      SeedProbe::CALLEE[def_node] << [receiver.describe(:short), shape, result ? result.describe(:short) : "nil",
                                      SeedProbe.tick, inclusive - frame[1]]
    end
    result
  end
end)

status = Rigor::CLI.start(ARGV)

stats = Hash.new(0)
cpu = Hash.new(0.0)
SeedProbe::CALLEE.each do |def_node, computes|
  main = SeedProbe::MAIN[def_node]
  computes.each do |recv, shape, res, seq, exclusive|
    stats[:computes] += 1
    cpu[:computes] += exclusive
    next if shape == :typed

    stats[:"shape_#{shape}"] += 1
    unless main
      stats[:no_main_pass_eval] += 1
      next
    end
    m_recv, m_dynamic, m_res, m_seq = main
    unless m_dynamic && recv == m_recv
      stats[recv == m_recv ? :main_params_not_dynamic : :receiver_differs] += 1
      next
    end
    stats[:key_matches_main] += 1
    cpu[:key_matches_main] += exclusive
    agree = res == m_res
    stats[agree ? :agree : :disagree] += 1
    next unless agree

    cpu[:agree] += exclusive
    if m_seq < seq
      stats[:agree_and_main_ran_first] += 1
      cpu[:agree_and_main_ran_first] += exclusive
    end
  end
end
out = { status: status, main_pass_defs: SeedProbe::MAIN.size, stats: stats, exclusive_cpu_s: cpu.transform_values { it.round(2) } }
File.write(ENV.fetch("OUT", "seed_probe.json"), JSON.pretty_generate(out))
warn JSON.generate(out)
