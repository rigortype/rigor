# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-129 G3 — deny by default: a file this spec covers keeps no typing state outside a declared `Rigor::TypingState`
# slot. Read by Prism, not by text, it flags:
#
# - per-thread, per-fiber and per-Ractor storage: `Thread.current`, `Fiber.current`, `Ractor.current`,
#   `thread_variable_get` / `_set`, `Fiber[]`, `Ractor[]`, `Ractor.store_if_absent`;
# - `ObjectSpace::WeakMap` and `WeakKeyMap`;
# - a module-level write: an instance variable written in a class or module body, at the top level, or in a singleton
#   method (`def self.x`, `class << self`, `module_function`, `extend self`), and any class-variable or global write;
# - a module-level instance variable called with anything but a reader (`@x[k] ||= v`, `@x << v`, `@x.merge(o)`), a
#   global or a constant mutated in place, and `instance_variable_get` / `_set`;
# - module state behind an accessor: a singleton `attr_accessor` / `attr_writer` (`singleton_class.attr_accessor`
#   included), and a setter, `||=` or in-place write through `self` at module level, `self.class`, a constant or a
#   constant's reader (`self.flag = v`, `self.class.x ||= {}`, `Owner.x ||= {}`, `Owner.lookup(k)[:x] = v`), or
#   through `send` / `public_send` with a setter's name;
# - a constant whose value is not frozen by construction, or a constant reassigned;
# - a read of one of the four advisory tables outside `Scope` (stage 2 puts them behind slots).
#
# The allow-list names each remaining site by file, rule and name, with how many there are and why. A site that is not
# listed, one more than listed, and a listed site that is gone all fail. ADR-129 WD5 allows for good only
# `TypingState` itself, the process counters and switches, and two shapes with a row naming their key each: a
# process-wide memo pure in its key, and a fiber-crossing per-thread sink typing never reads (#2814). Any other entry
# is a slot still to declare, and says which stage declares it.
#
# A comparison of `Thread.current`, `Fiber.current` or `Ractor.current` (`Ractor.current == Ractor.main`) reads no
# storage and is not flagged. Nor is `Ractor.main.send(m)` / `Ractor.main << m` inside a `Ractor.new` block (worker to
# main) whose value is discarded (or a local that is only ever assigned `Ractor.main` and used that way), or
# `Ractor.current.default_port` passed to `monitor` / `unmonitor`: the Ractor is an address there, not a store. Those
# calls answer the Ractor itself, so `Ractor.main.send(m)[:k]` is storage and flagged, as are `Ractor.main.send(m)`
# outside `Ractor.new` (the main mailbox as a queue), `Ractor.current.send`, `Ractor.current[:k]`, `Ractor[:k]` and
# `store_if_absent`. A local alias of a module (`owner = Folding; owner.fold = true`) and a Ractor read back
# through `binding.local_variable_get(:r)[:k]` are beyond a syntactic scan; G1 (stage 3) is what catches state reached
# that way.
#
# Stage 1 converts files a PR at a time; each conversion adds its files to {#covered_files}.
RSpec.describe "ADR-129 G3: typing state outside a declared slot" do
  def covered_files = analysis_files + inference_files + other_files

  def analysis_files
    %w[
      lib/rigor/analysis/check_rules.rb
      lib/rigor/analysis/dependency_recorder.rb
      lib/rigor/analysis/run_disclosure_credit.rb
      lib/rigor/analysis/runner/pool_coordinator.rb
      lib/rigor/analysis/self_call_resolution_recorder.rb
      lib/rigor/cache/file_digest.rb
      lib/rigor/effects/collector.rb
      lib/rigor/environment/rbs_loader.rb
    ]
  end

  def inference_files
    %w[
      lib/rigor/inference/acceptance.rb
      lib/rigor/inference/alias_mutation_floor.rb
      lib/rigor/inference/budget_trace.rb
      lib/rigor/inference/construction_escape.rb
      lib/rigor/inference/def_node_resolver.rb
      lib/rigor/inference/definers_index.rb
      lib/rigor/inference/expression_typer.rb
      lib/rigor/inference/flow_tracer.rb
      lib/rigor/inference/key_presence_guard.rb
      lib/rigor/inference/loop_value_record.rb
      lib/rigor/inference/method_dispatcher/interface_shape.rb
      lib/rigor/inference/memo_audit.rb
      lib/rigor/inference/method_dispatcher.rb
      lib/rigor/inference/method_dispatcher/rbs_dispatch.rb
      lib/rigor/inference/project_method_ownership.rb
      lib/rigor/inference/project_patched_scanner.rb
      lib/rigor/inference/rbs_type_translator.rb
      lib/rigor/inference/refined_dispatch/constructed_class.rb
      lib/rigor/inference/refined_dispatch/own_method.rb
      lib/rigor/inference/reflective_ivar_write.rb
      lib/rigor/inference/remover_holder_scan.rb
      lib/rigor/inference/scope_indexer.rb
      lib/rigor/inference/scope_indexer/declared_param_writes.rb
      lib/rigor/inference/scope_indexer/ivar_contributions.rb
      lib/rigor/inference/self_call_ivar_writes.rb
      lib/rigor/inference/statement_evaluator.rb
      lib/rigor/inference/toplevel_def_census.rb
      lib/rigor/inference/void_tail_summary.rb
    ]
  end

  def other_files
    %w[
      lib/rigor/plugin/io_boundary.rb
      lib/rigor/reflection/constant_ancestors.rb
      lib/rigor/scope.rb
      lib/rigor/scope/resolution_chain.rb
      lib/rigor/typing_state.rb
    ]
  end

  # `[file, rule, name] => [count, reason]`.
  def allow_list = typing_state_rows.merge(process_switch_rows, storage_rows)

  def typing_state_rows
    state = "lib/rigor/typing_state.rb"
    typer = "lib/rigor/inference/expression_typer.rb"
    evaluator = "lib/rigor/inference/statement_evaluator.rb"
    hand_off = "hands the store to a new body scope, not an entry read: entries go through Scope's logged readers " \
               "(the bound Table slots, ADR-129 WD1)"
    {
      [state, :thread_state, "Thread.current"] => [3, "the one per-thread anchor every slot lives in"],
      [state, :weak_map, "WeakKeyMap"] => [1, "State#weak_key_map makes the store a run-scoped Table or Memo holds"],
      [state, :module_ivar_write, "@slots"] => [2, "the slot registry, written only while files load"],
      [state, :module_ivar_write, "@run_scoped"] => [2, "the run-scoped slot indices, written only while files load"],
      [typer, :table_access, "dynamic_origins"] => [1, hand_off],
      [evaluator, :table_access, "dynamic_origins"] => [1, hand_off]
    }
  end

  # The process counters and switches ADR-129 WD5 names, which are never read back into a type.
  def process_switch_rows
    budget = "lib/rigor/inference/budget_trace.rb"
    counters = "BudgetTrace's process counters (ADR-129 WD5), never read back into a type"
    {
      [budget, :module_ivar_write, "@enabled"] => [3, "BudgetTrace's process switch (ADR-129 WD5)"],
      [budget, :module_ivar_write, "@mutex"] => [1, "guards BudgetTrace's process counters"],
      [budget, :module_ivar_write, "@counts"] => [1, counters],
      [budget, :module_ivar_mutation, "@counts"] => [2, counters],
      [budget, :module_ivar_write, "@distributions"] => [1, counters],
      [budget, :module_ivar_mutation, "@distributions"] => [3, counters],
      [budget, :module_ivar_write, "@distinct_seen"] => [1, counters],
      [budget, :module_ivar_mutation, "@distinct_seen"] => [1, counters],
      ["lib/rigor/inference/memo_audit.rb", :module_ivar_write, "@enabled"] =>
        [3, "MemoAudit's process switch (ADR-129 WD5)"]
    }.merge(activation_count_rows)
  end

  # The two shapes ADR-129 WD5 allows outside TypingState besides its own storage and the process counters (user
  # decision 2026-11-05, option A). Each row names its key, and the shape:
  #
  # 1. a process-wide memo whose value is built from its key and frozen constants alone, reading no scope, environment,
  #    run option or typing state;
  # 2. a per-thread output sink that crosses fibers on purpose and that typing never reads. Stage 2 must treat such a
  #    sink as a Resource before a capture opens around plugin code (#2814).
  def storage_rows
    loader = "lib/rigor/environment/rbs_loader.rb"
    acceptance = "lib/rigor/inference/acceptance.rb"
    memo = "WD5 shape 1, a process-wide memo pure in its key"
    default = "#{memo}: RbsLoader.default's `@default` is `RbsLoader.new` with no argument, which reads no scope, " \
              "environment, run option or typing state, and stays shared by every thread"
    parts = "#{memo}: `class_name_parts` is the split of its String argument, the `@class_name_parts` key, and reads " \
            "nothing else; a non-main Ractor cannot read it and answers nil, as before"
    translator = "lib/rigor/inference/rbs_type_translator.rb"
    names = "#{memo}: `relative_name` is the frozen `type_name.relative!.to_s` of its `RBS::TypeName` key, the " \
            "`@relative_names` key (#775), and reads no scope, environment, run option or typing state; a non-main " \
            "Ractor cannot read it, as before"
    {
      [loader, :module_ivar_write, "@default"] => [2, default],
      [translator, :module_ivar_write, "@relative_names"] => [1, names],
      [translator, :module_ivar_mutation, "@relative_names"] => [1, names],
      [acceptance, :module_ivar_write, "@class_name_parts"] => [1, parts],
      [acceptance, :module_ivar_mutation, "@class_name_parts"] => [1, parts]
    }.merge(sink_rows)
  end

  # WD5 shape 2: thread-variable sinks that cross fibers on purpose (an `Enumerator` in plugin code still lands in
  # them) and that typing never reads.
  def sink_rows
    boundary = "lib/rigor/plugin/io_boundary.rb"
    credit = "lib/rigor/analysis/run_disclosure_credit.rb"
    shape = "WD5 shape 2, a per-thread output sink typing never reads whose appends touch a Resource slot (#2814)"
    {
      [boundary, :thread_state, "Thread.current"] => [4, "#{shape}: IoBoundary.attributing's ATTRIBUTION_KEY"],
      [boundary, :thread_state, "thread_variable_get"] => [2, "#{shape}: IoBoundary's ATTRIBUTION_KEY"],
      [boundary, :thread_state, "thread_variable_set"] => [2, "#{shape}: IoBoundary's ATTRIBUTION_KEY"],
      [credit, :thread_state, "Thread.current"] => [4, "#{shape}: RunDisclosureCredit's ATTRIBUTION_KEY"],
      [credit, :thread_state, "thread_variable_get"] => [2, "#{shape}: RunDisclosureCredit's ATTRIBUTION_KEY"],
      [credit, :thread_state, "thread_variable_set"] => [2, "#{shape}: RunDisclosureCredit's ATTRIBUTION_KEY"]
    }
  end

  # A switch whose activation count keeps the disabled path an integer read (ADR-129 WD5), and the mutex guarding it.
  def activation_count_rows
    switch = "a process switch (ADR-129 WD5): the activation count keeps the disabled path an integer read"
    %w[
      lib/rigor/inference/flow_tracer.rb lib/rigor/effects/collector.rb lib/rigor/analysis/dependency_recorder.rb
      lib/rigor/analysis/self_call_resolution_recorder.rb
    ].each_with_object({}) do |file, rows|
      rows[[file, :module_ivar_write, "@active_count"]] = [3, switch]
      rows[[file, :module_ivar_write, "@mutex"]] = [1, "guards the activation count"]
    end
  end

  def table_readers = %i[dynamic_origins void_origins plugin_typed_calls optimistic_origins]

  def mutators
    %i[
      []= << push append prepend unshift insert concat store update merge! replace clear delete delete_if keep_if
      select! reject! filter! map! collect! compact! flatten! uniq! sort! sort_by! reverse! rotate! fill shift pop
      slice! transform_values! transform_keys! compare_by_identity add add? subtract default= rehash
    ]
  end

  # The calls on a module-level instance variable that only read it. Any other call may change it in place.
  def ivar_readers
    %i[
      [] fetch dig key? include? member? has_key? size length count empty? any? none? all? one? find detect each
      each_with_index each_with_object each_key each_value each_pair map flat_map filter_map select reject sum min max
      sort sort_by group_by first last take to_a to_h to_s inspect keys values values_at dup frozen? positive?
      negative? zero? nil? equal? eql? == != hash is_a? respond_to? call synchronize index find_index
    ]
  end

  def scalar_nodes
    [Prism::SymbolNode, Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode,
     Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::RegularExpressionNode, Prism::SourceFileNode,
     Prism::SourceLineNode, Prism::SourceEncodingNode, Prism::ConstantReadNode, Prism::ConstantPathNode]
  end

  def ivar_writes
    [Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
     Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableTargetNode]
  end

  def cvar_and_global_writes
    [Prism::ClassVariableWriteNode, Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
     Prism::ClassVariableOperatorWriteNode, Prism::ClassVariableTargetNode, Prism::GlobalVariableWriteNode,
     Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode, Prism::GlobalVariableOperatorWriteNode,
     Prism::GlobalVariableTargetNode]
  end

  def receiver_writes
    [Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexOperatorWriteNode, Prism::IndexTargetNode,
     Prism::CallOrWriteNode, Prism::CallAndWriteNode, Prism::CallOperatorWriteNode, Prism::CallTargetNode]
  end

  def constant_reassignments
    [Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode,
     Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode]
  end

  # The `Data.define` classes `lib/` names, by their last segment: a `.new` of one is frozen when its fields are.
  let(:lib_data_classes) do
    Dir[project_path("lib/**/*.rb")].flat_map { |path| data_classes_in(File.read(path)) }.to_set
  end

  def data_classes_in(source) = source.scan(/^\s*([A-Z]\w*) = Data\.define\b/).flatten

  # Every finding in `source` as `[path, rule, name, line]`.
  def findings_in(source, path) = scan(source, path)[:findings]

  # The scan state of `source`: its findings, and how many `thread_variable_*` calls sit directly on a
  # `Thread.current` that G3 reports as a finding of its own (`:chained`).
  def scan(source, path)
    result = Prism.parse(source)
    raise "#{path}: #{result.errors.first.message}" if result.failure?

    frozen_strings = result.magic_comments.any? do |comment|
      comment.key == "frozen_string_literal" && comment.value == "true"
    end
    file = { path: path, frozen_strings: frozen_strings, data: lib_data_classes | data_classes_in(source),
             findings: [], identity_reads: Set.new, chained: 0 }
    note_messaging_identity(result.value, file)
    walk(result.value, :top, file)
    file
  end

  # The calls on a Ractor that G3 may read as addressing a mailbox rather than storing in it, and that are public
  # `Ractor` instance methods on Ruby 4.0.5. `Ractor#send`, `#<<` and `#unmonitor` answer the receiving Ractor itself,
  # so a call counts only while its value is discarded.
  def messaging_calls = %i[send << monitor unmonitor]

  # A block whose value its caller discards, so the block's last statement is a discarded statement. Only `loop`:
  # `pool_coordinator.rb`'s worker ends its message loop with `main.send`, and a name-matched `each` or `times` would
  # also match a custom iterator that stores what its block returns.
  def discarding_iterators = %i[loop]

  def ractor_identity_call?(node, name = nil)
    node.is_a?(Prism::CallNode) && (name ? node.name == name : %i[current main].include?(node.name)) &&
      named_constant?(node.receiver, :Ractor)
  end

  # Marks a `Ractor.main` / `Ractor.current` as an identity read, an address and no store, in two cases:
  #
  # - `Ractor.main.send(m)` / `Ractor.main << m`, or the same through a local (`main = Ractor.main; main.send(m)`),
  #   lexically inside a `Ractor.new` block, where it is worker-to-main messaging, and with its value discarded: a
  #   non-last statement, or the last of a `loop` block. Outside `Ractor.new` the main Ractor's own mailbox is a queue
  #   (`Ractor.main.send(v)` here, `Ractor.receive` there). A messaging call's value is the Ractor, so
  #   `Ractor.main.send(m)[:k]` or `x = Ractor.main.send(m)` is storage. The local counts when every write to its name
  #   (anywhere in the file, any scope) is a discarded `name = Ractor.main` inside a `Ractor.new` block, and every read
  #   of it is the receiver of a discarded `send` / `<<`. A parameter of that name, another kind of write (`r = nil`,
  #   `r = Ractor.current`, a target, an operator write) or any other read disqualifies it. A def's last expression is
  #   returned, so it never counts.
  # - `Ractor.current.default_port` as an argument of `monitor` / `unmonitor`.
  #
  # `Ractor.current.send` and `<<` never count: a Ractor's own mailbox, written and read back, is a queue.
  def note_messaging_identity(root, file)
    state = { discarded: Set.new, worker: Set.new, calls: [], writes: [], reads: Hash.new(0), other: Set.new }
    stack = [[root, false]]
    until stack.empty?
      node, worker = stack.pop
      state[:worker] << node.object_id if worker
      tally_messaging(node, state)
      node.compact_child_nodes.each { |child| stack << [child, worker || worker_block?(node, child)] }
    end
    resolve_messaging(file, state)
  end

  # Whether `child` is the block of a `Ractor.new` call `node`.
  def worker_block?(node, child)
    node.is_a?(Prism::CallNode) && node.name == :new && named_constant?(node.receiver, :Ractor) &&
      child.equal?(node.block)
  end

  def tally_messaging(node, state)
    case node
    when Prism::StatementsNode then node.body[0...-1].each { |statement| state[:discarded] << statement.object_id }
    when Prism::CallNode then tally_message(node, state)
    when Prism::LocalVariableReadNode then state[:reads][node.name] += 1
    when Prism::LocalVariableWriteNode then state[:writes] << node
    else state[:other] << node.name if other_local_binding?(node)
    end
  end

  def tally_message(node, state)
    state[:calls] << node if messaging_calls.include?(node.name)
    block = node.block
    return unless discarding_iterators.include?(node.name) && block.is_a?(Prism::BlockNode)

    last = block.body.is_a?(Prism::StatementsNode) ? block.body.body.last : nil
    state[:discarded] << last.object_id if last
  end

  def resolve_messaging(file, state)
    messaged = Hash.new(0)
    state[:calls].each do |call|
      if %i[monitor unmonitor].include?(call.name)
        call_arguments(call).each { |argument| note_default_port(argument, file) }
      elsif state[:discarded].include?(call.object_id) && state[:worker].include?(call.object_id)
        main_messaging(call, file, messaged)
      end
    end
    resolve_main_locals(file, state, messaged)
  end

  def note_default_port(argument, file)
    return unless argument.is_a?(Prism::CallNode) && argument.name == :default_port

    file[:identity_reads] << argument.receiver.object_id if ractor_identity_call?(argument.receiver, :current)
  end

  def main_messaging(call, file, messaged)
    receiver = call.receiver
    file[:identity_reads] << receiver.object_id if ractor_identity_call?(receiver, :main)
    messaged[receiver.name] += 1 if receiver.is_a?(Prism::LocalVariableReadNode)
  end

  # A discarded `name = Ractor.main` inside a `Ractor.new` block.
  def worker_main_write?(write, state)
    ractor_identity_call?(write.value, :main) && state[:discarded].include?(write.object_id) &&
      state[:worker].include?(write.object_id)
  end

  def resolve_main_locals(file, state, messaged)
    assigned = Hash.new { |hash, key| hash[key] = [] }
    state[:writes].each do |write|
      if worker_main_write?(write, state)
        assigned[write.name] << write.value
      else
        state[:other] << write.name
      end
    end
    assigned.each do |name, values|
      next if state[:other].include?(name) || state[:reads][name] != messaged[name]

      values.each { |value| file[:identity_reads] << value.object_id }
    end
  end

  # Every other way to bind or rewrite a local: a target, an operator write, a parameter or a block-local.
  def other_local_binding?(node)
    node.class.name.match?(/\APrism::(LocalVariable.*(Write|Target)|.*Parameter|BlockLocalVariable)Node\z/) &&
      node.respond_to?(:name) && node.name
  end

  # `context` is `:top`, `:module_body`, `:singleton` (a singleton method or `class << self`) or `:instance`.
  def walk(node, context, file)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      walk(node.superclass, context, file) if node.is_a?(Prism::ClassNode) && node.superclass
      walk_body(node.body, :module_body, file)
    when Prism::SingletonClassNode
      walk(node.expression, context, file)
      walk_body(node.body, :singleton, file)
    when Prism::DefNode
      walk_def(node, node.receiver || context == :singleton ? :singleton : :instance, file)
    else
      check(node, context, file)
      node.compact_child_nodes.each { |child| walk(child, child_context(node, child, context), file) }
    end
  end

  # A `define_method` block is an instance method's body.
  def child_context(node, child, context)
    node.is_a?(Prism::CallNode) && node.name == :define_method && child.equal?(node.block) ? :instance : context
  end

  def walk_def(node, context, file)
    walk(node.parameters, context, file) if node.parameters
    walk(node.body, context, file) if node.body
  end

  # A module body's defs after a bare `module_function`, named by `module_function :x`, or under `extend self` are
  # singleton methods too.
  def walk_body(body, context, file)
    return if body.nil?

    statements = body.is_a?(Prism::StatementsNode) ? body.body : [body]
    singleton = module_function_defs(statements)
    # Under `extend self` the body's instance methods and accessors are its own singleton ones too, so the whole body
    # reads as a singleton context.
    context = :singleton if context == :module_body && extends_self?(statements)
    statements.each_with_index do |statement, position|
      if statement.is_a?(Prism::DefNode) && context == :module_body && singleton.call(position, statement)
        walk_def(statement, :singleton, file)
      else
        walk(statement, context, file)
      end
    end
  end

  # A predicate over a body's defs: whether `module_function` or `extend self` makes the def at `position` a
  # singleton method too.
  def module_function_defs(statements)
    extended = statements.any? { |node| bare_call?(node, :extend) && call_arguments(node).any?(Prism::SelfNode) }
    marks = statements.select { |node| bare_call?(node, :module_function) }
    all_from = statements.index { |node| bare_call?(node, :module_function) && call_arguments(node).empty? }
    named = marks.flat_map { |node| call_arguments(node).grep(Prism::SymbolNode).map { |name| name.unescaped.to_sym } }
    lambda do |position, definition|
      extended || named.include?(definition.name) || (!all_from.nil? && position > all_from)
    end
  end

  def extends_self?(statements)
    statements.any? { |node| bare_call?(node, :extend) && call_arguments(node).any?(Prism::SelfNode) }
  end

  def bare_call?(node, name) = node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == name

  def call_arguments(node) = node.arguments&.arguments || []

  def module_level?(context) = context != :instance

  def found(file, node, rule, name)
    file[:findings] << [file[:path], rule, name.to_s, node.location.start_line]
  end

  def check(node, context, file)
    case node
    when Prism::CallNode then check_call(node, context, file)
    when Prism::ConstantReadNode, Prism::ConstantPathNode
      found(file, node, :weak_map, node.name) if %i[WeakMap WeakKeyMap].include?(node.name)
    when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
      found(file, node, :unfrozen_constant, constant_name(node)) unless frozen_value?(node.value, file)
    when *constant_reassignments then found(file, node, :constant_reassign, constant_name(node))
    else check_write(node, context, file)
    end
  end

  def check_write(node, context, file)
    case node
    when *ivar_writes then found(file, node, :module_ivar_write, node.name) if module_level?(context)
    when *cvar_and_global_writes then found(file, node, :module_variable_write, node.name)
    when *receiver_writes then check_receiver_write(node, context, file)
    end
  end

  # `@x[k] ||= v`, `@x[k][j] += 1`, `$g[k] = v`, `self.x ||= v`, `Owner.x ||= v`, `Owner.x[k] = v`, `CONST[k] ||= v`.
  def check_receiver_write(node, context, file)
    receiver = node.receiver
    if (root = ivar_root(receiver))
      found(file, node, :module_ivar_mutation, root.name) if module_level?(context)
    elsif receiver.is_a?(Prism::GlobalVariableReadNode)
      found(file, node, :module_variable_write, receiver.name)
    elsif module_state_receiver?(receiver, context)
      found(file, node, :module_accessor_write, node.respond_to?(:read_name) ? node.read_name : state_name(receiver))
    end
  end

  def check_call(node, context, file)
    name = node.name
    note_identity_reads(node, file)
    check_thread_state(node, file)
    check_reflective_send(node, context, file)
    check_module_state_call(node, context, file)
    found(file, node, :table_access, name) if table_readers.include?(name)
    if %i[instance_variable_set instance_variable_get class_variable_set const_set].include?(name)
      found(file, node, :ivar_reflection, name)
    end
    found(file, node, :module_accessor, name) if accessor_macro?(node, context)
  end

  def check_module_state_call(node, context, file)
    name = node.name
    receiver = node.receiver
    if (root = ivar_root(receiver))
      found(file, node, :module_ivar_mutation, root.name) if module_level?(context) && !ivar_readers.include?(name)
    elsif receiver.is_a?(Prism::GlobalVariableReadNode)
      found(file, node, :module_variable_write, receiver.name) if mutators.include?(name)
    elsif setter?(name) && module_state_receiver?(receiver, context)
      found(file, node, :module_accessor_write, name.to_s.delete_suffix("="))
    elsif mutators.include?(name) && (constant?(receiver) || accessor_read?(receiver))
      found(file, node, :module_accessor_write, state_name(receiver))
    end
  end

  # `X.current == …`, `… == X.current` and `X.current.equal?(…)` compare identities; they read no storage.
  def note_identity_reads(node, file)
    return unless %i[== != equal?].include?(node.name)

    [node.receiver, *node.arguments&.arguments].each do |operand|
      file[:identity_reads] << operand.object_id if local_storage_call?(operand)
    end
  end

  def local_storage_call?(node)
    node.is_a?(Prism::CallNode) && %i[current main].include?(node.name) && local_storage_owner?(node.receiver)
  end

  # `send(:x=, v)`, `public_send(:current)` and the like, which spell a setter or a storage read the rules above match
  # by name.
  def check_reflective_send(node, context, file)
    return unless %i[send public_send __send__].include?(node.name)

    first = node.arguments&.arguments&.first
    return unless first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)

    sent = first.unescaped.to_sym
    if accessor_macro_named?(node.receiver, sent, context)
      found(file, node, :module_accessor, sent)
    elsif %i[current main].include?(sent) && local_storage_owner?(node.receiver)
      found(file, node, :thread_state, "#{node.receiver.name}.#{sent}")
    elsif setter?(sent) && sent_to_module_state?(node.receiver, context)
      found(file, node, :module_accessor_write, sent.to_s.delete_suffix("="))
    end
  end

  def sent_to_module_state?(receiver, context)
    receiver.nil? ? module_level?(context) : module_state_receiver?(receiver, context)
  end

  def check_thread_state(node, file)
    name = node.name
    receiver = node.receiver
    if local_storage_call?(node) && !file[:identity_reads].include?(node.object_id)
      found(file, node, :thread_state, "#{receiver.name}.#{name}")
    end
    if %i[thread_variable_get thread_variable_set thread_variable? storage store_if_absent].include?(name)
      found(file, node, :thread_state, name)
      file[:chained] += 1 if name.start_with?("thread_variable") && local_storage_call?(receiver)
    end
    return unless %i[[] []=].include?(name) && (named_constant?(receiver, :Fiber) || named_constant?(receiver, :Ractor))

    found(file, node, :thread_state, "#{receiver.name}#{name}")
  end

  def ivar_read?(node) = node.is_a?(Prism::InstanceVariableReadNode)

  # The instance variable `node` reads, directly or through a chain of element readers (`@h[k]`, `@h.fetch(k)`,
  # `@h[k][j]`), so a mutation of what the chain answers is a mutation of the ivar's contents; nil otherwise. A reader
  # that answers a copy (`dup`, `to_a`, `map`) ends the chain. A local alias (`seen = @h[k]; seen.add(x)`) is beyond
  # the scan.
  def ivar_root(node)
    node = node.receiver while node.is_a?(Prism::CallNode) && element_readers.include?(node.name) && node.receiver
    ivar_read?(node) ? node : nil
  end

  def element_readers = %i[[] fetch dig first last find detect]

  def local_storage_owner?(node) = %i[Thread Fiber Ractor].any? { |name| named_constant?(node, name) }

  def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

  def setter?(name) = name.end_with?("=") && !%i[== != <= >= === []= =~].include?(name)

  # A reader call on a constant or on `self.class` (`Owner.x`, `Owner.lookup(k)`, `self.class.x`), not a constructor
  # and not the per-thread storage the thread-state rule reports: what an index write or a mutator through it changes
  # is module state.
  def accessor_read?(node)
    return false unless node.is_a?(Prism::CallNode) && (constant?(node.receiver) || self_class?(node.receiver))
    return false if %i[new allocate].include?(node.name) || local_storage_call?(node)

    !(node.name == :[] && %i[Set Hash Array].any? { |name| named_constant?(node.receiver, name) })
  end

  def self_class?(node) = node.is_a?(Prism::CallNode) && node.name == :class && node.receiver.is_a?(Prism::SelfNode)

  def module_state_receiver?(receiver, context)
    constant?(receiver) || self_class?(receiver) || accessor_read?(receiver) ||
      (receiver.is_a?(Prism::SelfNode) && module_level?(context))
  end

  def state_name(node) = node.respond_to?(:name) ? node.name : node.class.name.split("::").last

  # `attr_accessor` / `attr_writer` in `class << self` or an `extend self` body (bare or through `self.`) or on
  # `singleton_class`, or a module attribute macro (`mattr_*`, `cattr_*`, `class_attribute`) with a nil, `self` or
  # `singleton_class` receiver. A plain `attr_accessor` in a class body defines instance accessors, which are not
  # module state. Spelled `send(:attr_writer, :x)` too ({#check_reflective_send}).
  def accessor_macro?(node, context) = accessor_macro_named?(node.receiver, node.name, context)

  def accessor_macro_named?(receiver, name, context)
    return true if %i[mattr_accessor mattr_writer cattr_accessor cattr_writer class_attribute].include?(name) &&
                   (receiver.nil? || receiver.is_a?(Prism::SelfNode) || singleton_class_call?(receiver))
    return false unless %i[attr_accessor attr_writer].include?(name)

    singleton_class_call?(receiver) || (context == :singleton && (receiver.nil? || receiver.is_a?(Prism::SelfNode)))
  end

  def singleton_class_call?(node) = node.is_a?(Prism::CallNode) && node.name == :singleton_class

  def named_constant?(node, name)
    (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && node.name == name
  end

  def constant_name(node) = node.respond_to?(:name) && node.name ? node.name : node.target.name

  # Whether a constant's value is frozen by construction: a scalar literal or another constant, a `.freeze` whose
  # collection literal nests no unfrozen one, `Ractor.make_shareable`, a class (`Data.define`, `Struct.new`,
  # `Class.new`, `Module.new`), a `TypingState` declaration (an Integer), an immutable `Rigor::Type` (ADR-3), or a
  # `Data` value whose fields are frozen.
  def frozen_value?(node, file)
    case node
    when *scalar_nodes then true
    when Prism::StringNode then file[:frozen_strings]
    when Prism::RangeNode then [node.left, node.right].compact.all? { |bound| frozen_value?(bound, file) }
    when Prism::ParenthesesNode then node.body.is_a?(Prism::StatementsNode) && frozen_value?(node.body.body.last, file)
    when Prism::CallNode then frozen_call?(node, file)
    else false
    end
  end

  def frozen_call?(node, file)
    receiver = node.receiver
    return frozen_literal?(receiver, file) if node.name == :freeze && receiver
    return true if frozen_factory?(receiver, node.name)
    return false unless node.name == :new && receiver.respond_to?(:name) && file[:data].include?(receiver.name.to_s)

    (node.arguments&.arguments || []).all? { |argument| frozen_argument?(argument, file) }
  end

  # A call whose answer is frozen whatever its arguments.
  def frozen_factory?(receiver, name)
    (named_constant?(receiver, :Ractor) && name == :make_shareable) ||
      (named_constant?(receiver, :Data) && name == :define) ||
      (%i[Struct Class Module].any? { |constant| named_constant?(receiver, constant) } && name == :new) ||
      (named_constant?(receiver, :TypingState) && %i[frame table resource memo].include?(name)) ||
      named_constant?(receiver, :Combinator)
  end

  def frozen_argument?(node, file)
    return frozen_value?(node, file) unless node.is_a?(Prism::KeywordHashNode)

    node.elements.all? { |element| element.is_a?(Prism::AssocNode) && frozen_value?(element.value, file) }
  end

  # The receiver of a `.freeze`: a collection literal whose every element is frozen by construction too (a splat of
  # another constant is). Any other receiver (a computed collection) is frozen at its top.
  def frozen_literal?(node, file)
    elements =
      case node
      when Prism::ArrayNode then node.elements
      when Prism::HashNode then node.elements.flat_map { |e| e.is_a?(Prism::AssocNode) ? [e.key, e.value] : [e] }
      else return true
      end
    elements.all? do |element|
      element.is_a?(Prism::SplatNode) ? constant?(element.expression) : frozen_value?(element, file)
    end
  end

  def project_path(path) = File.expand_path("../../#{path}", __dir__)

  it "keeps no typing state outside a declared slot in a covered file" do
    found = covered_files.flat_map { |path| findings_in(File.read(project_path(path)), path) }
    counts = found.group_by { |finding| finding.first(3) }.transform_values(&:size)
    expected = allow_list.transform_values(&:first)

    unlisted = found.reject { |finding| counts[finding.first(3)] == expected[finding.first(3)] }
    stale = expected.reject { |key, count| counts[key] == count }
    expect(unlisted.map { |file, rule, name, line| "#{file}:#{line} #{rule} #{name}" }).to be_empty
    expect(stale).to be_empty
  end

  # The ADR-129 stage 1 ratchet: the `Thread.current` / `thread_variable_*` call sites that no conversion has reached
  # yet, per file, under the directories stage 1 covers. A site is one call: `Thread.current[:k]` is one, and
  # `Thread.current.thread_variable_get(:k)` is one (the `thread_variable_*` call, not also its receiver). Compared for
  # equality, so a new site anywhere in these directories fails, and a conversion that does not update the Hash fails
  # too. A file leaves the Hash when its last site becomes a declared slot, or an allow-list row accounts for it
  # (WD5's fiber-crossing sinks, {#sink_rows}); it never gains a row. The Hash spans the nine directories G3
  # covers; PRs before #2811 counted six (without `plugin`, `type` and `cache`).
  def unconverted_thread_sites
    {}
  end

  # ADR-129's G3 scope, which the ratchet shares.
  def stage1_directories = %w[inference scope reflection analysis effects environment plugin type cache]

  def stage1_files
    directories = stage1_directories.flat_map { |dir| Dir[project_path("lib/rigor/#{dir}/**/*.rb")] }
    siblings = stage1_directories.map { |name| project_path("lib/rigor/#{name}.rb") }
    (directories + siblings).select { |path| File.file?(path) }.uniq.sort
  end

  # G3's own thread-state rule, so every spelling it flags counts (`::Thread.current`, `Thread.send(:current)`,
  # `Fiber[]`, `Ractor.current[]`, `thread_variable_*`, ...), with a `thread_variable_*` on a `Thread.current` one site.
  # A `:thread_state` finding that an allow-list row accounts for is not a site; a file whose findings all are has none.
  def thread_site_count(source, path)
    file = scan(source, path)
    found = file[:findings].select { |finding| finding[1] == :thread_state }
    unaccounted = found.size - allowed_thread_findings(path)
    # A chained `Thread.current.thread_variable_*` is one site of two findings. The rows account for chained calls first
    # (the sinks' are all chained), so the chained ones left over are the file's chained calls beyond the rows'
    # `thread_variable_*` count, and an unchained `thread.thread_variable_get` that is not a row stays a whole site.
    unaccounted_variables = found.count { |finding| finding[2].start_with?("thread_variable") } -
                            allowed_thread_findings(path, variables: true)
    chained = (file[:chained] - allowed_thread_findings(path, variables: true)).clamp(0, [unaccounted_variables, 0].max)
    unaccounted - chained
  end

  def allowed_thread_findings(path, variables: false)
    relative = path.delete_prefix("#{project_path('')}/")
    allow_list.sum do |(file, rule, name), (count, _)|
      file == relative && rule == :thread_state && (!variables || name.start_with?("thread_variable")) ? count : 0
    end
  end

  it "counts the unconverted G3 thread-state sites per file (ADR-129 stage 1 ratchet)" do
    counted = stage1_files.to_h do |path|
      [path.delete_prefix("#{project_path('')}/"), thread_site_count(File.read(path), path)]
    end
    found = counted.reject { |_, count| count.zero? }

    expect(found).to eq(unconverted_thread_sites), <<~MESSAGE
      ADR-129 stage 1: G3's thread-state sites (Thread/Fiber/Ractor storage and identity reads) under
      lib/rigor/{inference,scope*,reflection,analysis,effects,environment,plugin,type,cache} must match this spec's
      Hash. New typing state belongs in a declared Rigor::TypingState slot, not here; a converted file's row is
      removed (or its count lowered) in the same change.
    MESSAGE
  end

  # The formula, on a file that has allow-list rows (the fiber-crossing sinks: 4 chained `thread_variable_*` calls).
  it "counts only a row-bearing file's unaccounted thread-state sites" do
    path = "lib/rigor/plugin/io_boundary.rb"
    source = File.read(project_path(path))
    count = ->(extra) { thread_site_count("#{source}\nmodule Probe\n#{extra}\nend\n", project_path(path)) }
    plain = ->(number) { (1..number).map { |index| "def self.p#{index} = Thread.current[:a]" }.join("\n") }

    expect(count.call("")).to eq(0)
    expect(count.call(plain.call(1))).to eq(1)
    expect(count.call(plain.call(4))).to eq(4)
    expect(count.call("def self.q(thread) = thread.thread_variable_get(:z)")).to eq(1)
    expect(count.call("def self.q = Thread.current.thread_variable_get(:z)")).to eq(1)
  end

  it "gives every allow-list entry a covered file and a reason" do
    allow_list.each do |(file, _, _), (count, reason)|
      expect(covered_files).to include(file)
      expect(count).to be_positive
      expect(reason.strip).not_to be_empty
    end
  end

  # A file that declares a slot has been converted, so this spec must cover it.
  it "covers every file that declares a TypingState slot" do
    declaring = Dir[project_path("lib/**/*.rb")].select do |path|
      File.read(path).match?(/\bTypingState\.(?:frame|table|resource|memo)\(/)
    end
    expect(declaring.map { |path| path.delete_prefix("#{project_path('')}/") } - covered_files).to be_empty
    expect(declaring).not_to be_empty
  end

  describe "the scanner" do
    def rules_in(source) = findings_in(source, "fixture.rb").map { |_, rule, name, line| [line, rule, name] }

    it "flags per-thread, per-fiber and weak-map state" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        def a = Thread.current[:k]
        def b = Thread.current.thread_variable_get(:k)
        def c = Fiber[:k]
        def d = Fiber.current.storage
        def e = ObjectSpace::WeakKeyMap.new
        def f(t) = t.thread_variable_set(:k, 1)
        def g = ObjectSpace::WeakMap.new
      RUBY
        [1, :thread_state, "Thread.current"], [2, :thread_state, "Thread.current"],
        [2, :thread_state, "thread_variable_get"], [3, :thread_state, "Fiber[]"], [4, :thread_state, "storage"],
        [4, :thread_state, "Fiber.current"], [5, :weak_map, "WeakKeyMap"], [6, :thread_state, "thread_variable_set"],
        [7, :weak_map, "WeakMap"]
      )
    end

    it "flags module-level writes and in-place mutations, and leaves instance state alone" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        module M
          @a = 1
          def self.b = @b ||= 2
          def self.c(key) = @c[key] ||= 3
          def self.d = @d << 4
          class << self
            def e = (@e = 5)
          end
          def instance = @instance ||= 6
        end
        class C
          def initialize = (@c = 1)
          define_method(:m) { @m = 2 }
          @@count = 0
        end
        $global = 1
      RUBY
        [2, :module_ivar_write, "@a"], [3, :module_ivar_write, "@b"], [4, :module_ivar_mutation, "@c"],
        [5, :module_ivar_mutation, "@d"], [7, :module_ivar_write, "@e"], [14, :module_variable_write, "@@count"],
        [16, :module_variable_write, "$global"]
      )
    end

    it "reads a def after `module_function`, named by it, or under `extend self` as a singleton method" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        module N
          def before = (@before = 1)
          def named = (@named = 1)
          module_function :named
          module_function

          def after = (@after = 2)
        end
        module O
          extend self

          def p = (@p = 1)
        end
      RUBY
        [3, :module_ivar_write, "@named"], [7, :module_ivar_write, "@after"], [12, :module_ivar_write, "@p"]
      )
    end

    it "flags a constant not frozen by construction, and a reassigned one" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        # frozen_string_literal: true
        A = [1]
        B = [1].freeze
        C = { a: [1] }.freeze
        D = Set[1]
        E = :sym
        F = Data.define(:x)
        G = F.new(x: 1)
        H = F.new(x: [])
        I = "s"
        J = "\#{E}"
        K ||= 1
        L = TypingState.frame(:x, reason: "y")
        M = Type::Combinator.constant_of(true)
        N = Ractor.make_shareable({ a: [1] })
      RUBY
        [2, :unfrozen_constant, "A"], [4, :unfrozen_constant, "C"], [5, :unfrozen_constant, "D"],
        [9, :unfrozen_constant, "H"], [11, :unfrozen_constant, "J"], [12, :constant_reassign, "K"]
      )
    end

    it "flags per-Ractor storage" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        def a = Ractor.current[:k]
        def b = Ractor[:k]
        def c = Ractor.store_if_absent(:k) { 1 }
      RUBY
        [1, :thread_state, "Ractor.current"], [2, :thread_state, "Ractor[]"], [3, :thread_state, "store_if_absent"]
      )
    end

    # Review of #2796: `MethodDispatcher::FileFolding` keeps a per-run flag behind a singleton accessor, which no ivar
    # node shows.
    it "flags module state behind an accessor, and a setter or in-place write through self or a constant" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        module Folding
          class << self
            attr_accessor :fold
          end
          self.fold = false
          def self.reset = (self.fold = true)
        end
        class Reader
          def a = Owner.x ||= {}
          def b(key) = Owner.x[key] = 1
          def c = Owner.x << 1
          def d = REGISTRY << 1
          def e = Set.new.compare_by_identity
          def f = self.name = 1
        end
      RUBY
        [3, :module_accessor, "attr_accessor"], [5, :module_accessor_write, "fold"],
        [6, :module_accessor_write, "fold"], [9, :module_accessor_write, "x"], [10, :module_accessor_write, "x"],
        [11, :module_accessor_write, "x"], [12, :module_accessor_write, "REGISTRY"]
      )
    end

    it "flags module state through self.class, singleton_class, a reader with arguments, Thread.main or send" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        class Reader
          def a = self.class.x ||= {}
          def b(key) = self.class.x[key] = 1
          def c = singleton_class.attr_accessor(:y)
          def d(key) = Owner.lookup(key)[:x] = 1
          def e = Thread.main[:k]
          def f = Thread.send(:current)[:k]
          def g = Owner.public_send(:x=, 1)
          def h = Set[1] << 2
        end
      RUBY
        [2, :module_accessor_write, "x"], [3, :module_accessor_write, "x"], [4, :module_accessor, "attr_accessor"],
        [5, :module_accessor_write, "lookup"], [6, :thread_state, "Thread.main"], [7, :thread_state, "Thread.current"],
        [8, :module_accessor_write, "x"]
      )
    end

    # Review of #2796, round 3, and of #2803: an accessor macro spelled through `send` or `self.`, or under `extend
    # self`, and not an instance accessor in a class body. A macro inside `singleton_class.class_eval { … }` is
    # beyond the scan, like a local alias.
    it "flags a module accessor macro however it is spelled, and not an instance accessor" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        class Owner
          singleton_class.send(:attr_accessor, :w)
          send(:attr_writer, :x)
          def self.y = public_send(:attr_reader, :z)
          class << self
            self.send(:attr_writer, :v)
            send("attr_accessor", :u)
            self.attr_writer :t
            send("flag=", 1)
          end
          send(:mattr_accessor, :s)
          singleton_class.mattr_accessor :n
        end
      RUBY
        [2, :module_accessor, "attr_accessor"], [6, :module_accessor, "attr_writer"],
        [7, :module_accessor, "attr_accessor"], [8, :module_accessor, "attr_writer"],
        [9, :module_accessor_write, "flag"], [11, :module_accessor, "mattr_accessor"],
        [12, :module_accessor, "mattr_accessor"]
      )
    end

    # Review of #2803, delta: an `extend self` body reads as a singleton context, whatever the spelling or nesting.
    it "flags an accessor macro anywhere in an extend self body" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        module Shared
          extend self

          attr_accessor :r
          send(:attr_accessor, :q)
          self.attr_writer :p
          attr_accessor :o if true
        end
      RUBY
        [4, :module_accessor, "attr_accessor"], [5, :module_accessor, "attr_accessor"],
        [6, :module_accessor, "attr_writer"], [7, :module_accessor, "attr_accessor"]
      )
    end

    it "reads an identity comparison of the current thread, fiber or Ractor as no storage, and a write once" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        def a = Ractor.current == Ractor.main
        def b(thread) = thread.equal?(Thread.current)
        def c = Thread.current[:k] = 1
      RUBY
        [3, :thread_state, "Thread.current"]
      )
    end

    # ADR-129 stage 1, PR 7: `Ractor.main.send(m)` and `worker.monitor(Ractor.current.default_port)` address a
    # mailbox; they keep nothing. A local counts only while every read of it is a messaging receiver.
    it "reads a worker's Ractor.main messages and Ractor.current's port given to monitor as addresses" do
      expect(rules_in(<<~RUBY)).to be_empty
        def worker
          Ractor.new do
            main = Ractor.main
            main.send(1)
            main << 2
            Ractor.main.send([:x])
            loop { Ractor.main << 3 }
          end
        end
        def b(worker) = worker.monitor(Ractor.current.default_port)
        def d(workers) = workers.each { |w| w.unmonitor(Ractor.current.default_port) }
        def e(worker, port) = worker.monitor(port)
        def f(obj) = obj.monitor(:x)
        def g = unmonitor(1)
        def h
          Ractor.new do
            r = Ractor.main
            r = Ractor.main
            r.send(1)
            nil
          end
        end
      RUBY
    end

    it "flags a Ractor that is stored in, passed on, rebound, read back or whose mailbox is a queue" do # rubocop:disable RSpec/ExampleLength
      expect(rules_in(<<~RUBY)).to contain_exactly(
        def e
          third = Ractor.main
          third.send(1)
          third = nil
          nil
        end
        def f = Ractor.current[:k]
        def g = Ractor.main[:k]
        def h = Ractor[:k]
        def i = Ractor.store_if_absent(:k) { 1 }
        def j(registry) = registry.hold(Ractor.main)
        def k(held) = (held = Ractor.main).send(1)
        def l(fourth) = fourth.send(Ractor.current)
        def m = Ractor.current.send(nil)[:memo]
        def n(v) = (Ractor.current << nil)[:memo] = v
        def o
          me = Ractor.main
          me.send(nil)[:memo] ||= {}
        end
        def stash(v) = Ractor.current.send(v)
        def unstash = Ractor.current.default_port.receive
        def p1
          Ractor.main.send(1)
        end
        def q
          r = Ractor.current
          [1].each { r = Ractor.main }
          r.send(1)
          nil
        end
        def s = Ractor.main.send(1).name
        def t
          kept = Ractor.main.send(1)
          kept
        end
        def u(sink) = sink.call(Ractor.current.default_port)
        def v = (pending = Ractor.main).send(1)
        def w
          Ractor.main.receive
          nil
        end
        def x
          Ractor.current.send(1)
          nil
        end
        def y = [1].map { Ractor.main.send(1) }
        def stash_main(v)
          Ractor.main.send(v)
          nil
        end
        def unstash_main = Ractor.receive
        def queue_local(v)
          me = Ractor.main
          me << v
          nil
        end
        def enum_each
          Enumerator.new { |y| y.yield(nil)[:memo] = 1 }.each { Ractor.main.send(nil) }
        end
        def each_yield = yield
        def custom
          each_yield { Ractor.main.send(nil) }
        end
        def r3(worker) = worker.monitor(Ractor.current[:k])
        def w2
          Ractor.new do
            other = Ractor.current
            other.send(1)
            nil
          end
        end
        def mixed
          held_main = Ractor.main
          Ractor.new do
            held_main.send(1)
            nil
          end
        end
      RUBY
        [2, :thread_state, "Ractor.main"], [7, :thread_state, "Ractor.current"], [8, :thread_state, "Ractor.main"],
        [9, :thread_state, "Ractor[]"], [10, :thread_state, "store_if_absent"], [11, :thread_state, "Ractor.main"],
        [12, :thread_state, "Ractor.main"], [13, :thread_state, "Ractor.current"],
        [14, :thread_state, "Ractor.current"], [15, :thread_state, "Ractor.current"],
        [17, :thread_state, "Ractor.main"], [20, :thread_state, "Ractor.current"],
        [21, :thread_state, "Ractor.current"], [23, :thread_state, "Ractor.main"],
        [26, :thread_state, "Ractor.current"], [27, :thread_state, "Ractor.main"],
        [31, :thread_state, "Ractor.main"], [33, :thread_state, "Ractor.main"], [36, :thread_state, "Ractor.current"],
        [37, :thread_state, "Ractor.main"], [39, :thread_state, "Ractor.main"],
        [43, :thread_state, "Ractor.current"], [46, :thread_state, "Ractor.main"],
        [48, :thread_state, "Ractor.main"], [53, :thread_state, "Ractor.main"], [58, :thread_state, "Ractor.main"],
        [62, :thread_state, "Ractor.main"], [64, :thread_state, "Ractor.current"],
        [67, :thread_state, "Ractor.current"], [73, :thread_state, "Ractor.main"]
      )
    end

    # Review of #2804: a mutation through an element reader is a mutation of the ivar's contents; one of a copy is not.
    it "flags a module ivar mutated through an element reader, and not a copy of it" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        module M
          def self.a(key, value) = @a[key] << value
          def self.b(key, other) = @b[key][other] += 1
          def self.c(key, value) = @c.fetch(key).push(value)
          def self.d(key) = @d[key].dup.freeze
          def self.e = @e.map(&:to_s).freeze
        end
      RUBY
        [2, :module_ivar_mutation, "@a"], [3, :module_ivar_mutation, "@b"], [4, :module_ivar_mutation, "@c"]
      )
    end

    it "flags a module ivar called with anything but a reader, and a global mutated in place" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        module M
          def self.a(other) = @a.merge(other)
          def self.b = @b.delete_at(0)
          def self.c = (@c.field = 1)
          def self.d(key) = @d.fetch(key)
          def self.e = @e.synchronize { 1 }
          def self.f(key) = instance_variable_get(:@f)[key] = 1
          def g = $g << 1
          def h = $stderr.puts("x")
        end
      RUBY
        [2, :module_ivar_mutation, "@a"], [3, :module_ivar_mutation, "@b"], [4, :module_ivar_mutation, "@c"],
        [7, :ivar_reflection, "instance_variable_get"], [8, :module_variable_write, "$g"]
      )
    end

    it "reads a frozen literal as frozen only when each element is" do
      expect(rules_in(<<~RUBY)).to contain_exactly(
        # frozen_string_literal: true
        A = { a: Set.new }.freeze
        B = [{}.compare_by_identity].freeze
        C = [Hash.new].freeze
        D = [:a, B, "s", 1..2, [1].freeze].freeze
        E = [*D, :b].freeze
        F = [*compute].freeze
      RUBY
        [2, :unfrozen_constant, "A"], [3, :unfrozen_constant, "B"], [4, :unfrozen_constant, "C"],
        [7, :unfrozen_constant, "F"]
      )
    end

    it "flags an advisory-table read and reflective state writes" do
      expect(rules_in(<<~RUBY)).to eq(
        def a(scope) = scope.dynamic_origins[1]
        def b(object) = object.instance_variable_set(:@x, 1)
      RUBY
        [[1, :table_access, "dynamic_origins"], [2, :ivar_reflection, "instance_variable_set"]]
      )
    end
  end
end
