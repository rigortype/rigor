# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-129 G3 — deny by default: a file this spec covers keeps no typing state outside a declared
# `Rigor::TypingState` slot. Read by Prism, not by text, it flags:
#
# - per-thread, per-fiber and per-Ractor storage: `Thread.current`, `Fiber.current`, `Ractor.current`,
#   `thread_variable_get` / `_set`, `Fiber[]`, `Ractor[]`, `Ractor.store_if_absent`;
# - `ObjectSpace::WeakMap` and `WeakKeyMap`;
# - a module-level write: an instance variable written in a class or module body, at the top level, or in a singleton
#   method (`def self.x`, `class << self`, `module_function`, `extend self`), and any class-variable or global write;
# - a module-level instance variable called with anything but a reader (`@x[k] ||= v`, `@x << v`, `@x.merge(o)`), a
#   global or a constant mutated in place, and `instance_variable_get` / `_set`;
# - module state behind an accessor: a singleton `attr_accessor` / `attr_writer`, and a setter, `||=` or in-place write
#   through `self` at module level or through a constant (`self.flag = v`, `Owner.x ||= {}`, `Owner.x[k] = v`);
# - a constant whose value is not frozen by construction, or a constant reassigned;
# - a read of one of the four advisory tables outside `Scope` (stage 2 puts them behind slots).
#
# The allow-list names each remaining site by file, rule and name, with how many there are and why. A site that is not
# listed, one more than listed, and a listed site that is gone all fail. ADR-129 WD5 allows only `TypingState` itself
# and the process counters on it for good; any other entry is a slot still to declare, and says which stage declares it.
#
# Stage 1 converts files a PR at a time; each conversion adds its files to {#covered_files}.
RSpec.describe "ADR-129 G3: typing state outside a declared slot" do
  def covered_files
    %w[
      lib/rigor/inference/expression_typer.rb
      lib/rigor/inference/key_presence_guard.rb
      lib/rigor/inference/statement_evaluator.rb
      lib/rigor/typing_state.rb
    ]
  end

  # `[file, rule, name] => [count, reason]`.
  def allow_list
    state = "lib/rigor/typing_state.rb"
    typer = "lib/rigor/inference/expression_typer.rb"
    evaluator = "lib/rigor/inference/statement_evaluator.rb"
    stage2 = "ADR-129 stage 2 puts the four advisory tables behind journaled Table slots"
    {
      [state, :thread_state, "Thread.current"] => [3, "the one per-thread anchor every slot lives in"],
      [state, :module_accessor_write, "current"] => [1, "TypingState.current stores the thread's new state"],
      [state, :thread_state, "Fiber.current"] => [2, "a state's owning fiber, so a cached state is dropped elsewhere"],
      [state, :weak_map, "WeakKeyMap"] => [1, "State#weak_key_map makes the store a run-scoped Table or Memo holds"],
      [state, :module_ivar_write, "@slots"] => [2, "the slot registry, written only while files load"],
      [state, :module_ivar_write, "@run_scoped"] => [2, "the run-scoped slot indices, written only while files load"],
      [typer, :table_access, "optimistic_origins"] => [1, stage2],
      [typer, :table_access, "dynamic_origins"] => [1, stage2],
      [evaluator, :table_access, "dynamic_origins"] => [2, stage2]
    }
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
  def findings_in(source, path)
    result = Prism.parse(source)
    raise "#{path}: #{result.errors.first.message}" if result.failure?

    frozen_strings = result.magic_comments.any? do |comment|
      comment.key == "frozen_string_literal" && comment.value == "true"
    end
    file = { path: path, frozen_strings: frozen_strings, data: lib_data_classes | data_classes_in(source),
             findings: [] }
    walk(result.value, :top, file)
    file[:findings]
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

  # `@x[k] ||= v`, `$g[k] = v`, `self.x ||= v`, `Owner.x ||= v`, `Owner.x[k] = v`, `CONST[k] ||= v`.
  def check_receiver_write(node, context, file)
    receiver = node.receiver
    if ivar_read?(receiver)
      found(file, node, :module_ivar_mutation, receiver.name) if module_level?(context)
    elsif receiver.is_a?(Prism::GlobalVariableReadNode)
      found(file, node, :module_variable_write, receiver.name)
    elsif module_state_receiver?(receiver, context)
      found(file, node, :module_accessor_write, node.respond_to?(:read_name) ? node.read_name : state_name(receiver))
    end
  end

  def check_call(node, context, file)
    name = node.name
    check_thread_state(node, file)
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
    if ivar_read?(receiver)
      found(file, node, :module_ivar_mutation, receiver.name) if module_level?(context) && !ivar_readers.include?(name)
    elsif receiver.is_a?(Prism::GlobalVariableReadNode)
      found(file, node, :module_variable_write, receiver.name) if mutators.include?(name)
    elsif setter?(name) && module_state_receiver?(receiver, context)
      found(file, node, :module_accessor_write, name.to_s.delete_suffix("="))
    elsif mutators.include?(name) && (constant?(receiver) || accessor_read?(receiver))
      found(file, node, :module_accessor_write, state_name(receiver))
    end
  end

  def check_thread_state(node, file)
    name = node.name
    receiver = node.receiver
    found(file, node, :thread_state, "#{receiver.name}.current") if name == :current && local_storage_owner?(receiver)
    if %i[thread_variable_get thread_variable_set thread_variable? storage store_if_absent].include?(name)
      found(file, node, :thread_state, name)
    end
    return unless %i[[] []=].include?(name) && (named_constant?(receiver, :Fiber) || named_constant?(receiver, :Ractor))

    found(file, node, :thread_state, "#{receiver.name}#{name}")
  end

  def ivar_read?(node) = node.is_a?(Prism::InstanceVariableReadNode)

  def local_storage_owner?(node) = %i[Thread Fiber Ractor].any? { |name| named_constant?(node, name) }

  def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

  def setter?(name) = name.end_with?("=") && !%i[== != <= >= === []= =~].include?(name)

  # A reader call on a constant (`Owner.x`, not a constructor): what an index write or a mutator through it changes is
  # module state.
  def accessor_read?(node)
    node.is_a?(Prism::CallNode) && node.arguments.nil? && constant?(node.receiver) &&
      !%i[new allocate].include?(node.name)
  end

  def module_state_receiver?(receiver, context)
    constant?(receiver) || accessor_read?(receiver) || (receiver.is_a?(Prism::SelfNode) && module_level?(context))
  end

  def state_name(node) = node.respond_to?(:name) ? node.name : node.class.name.split("::").last

  # `attr_accessor` / `attr_writer` in `class << self`, or a module attribute macro anywhere.
  def accessor_macro?(node, context)
    return false unless node.receiver.nil?

    (context == :singleton && %i[attr_accessor attr_writer].include?(node.name)) ||
      %i[mattr_accessor mattr_writer cattr_accessor cattr_writer class_attribute].include?(node.name)
  end

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
