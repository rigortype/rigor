# frozen_string_literal: true

require "prism"
require "rigor/inference/call_ladder"
require_relative "call_ladder_pin"

# The Prism reading behind `spec/rigor/inference/call_ladder/port_spec.rb` and `reentry_spec.rb` (ADR-116 WD12): what
# a rung module does with the typer it is given and what it exposes, and who calls the typer's re-entry points and the
# dispatcher's interior. The rules, and what the reading cannot see, are in the two specs' headers.
#
# As in {CallLadderPin}, every name comes from a table of `Rigor::Inference::CallLadder`: `PORT`, `PUBLIC_CALLBACKS`,
# `REENTRY`, `SECOND_ENTRIES` and `DISPATCHER_INTERIOR`, and `RUNGS` for a rung's own entry. A rung slice edits the
# tables and not this file.
module CallLadderPort
  ROOT = CallLadderPin::ROOT
  LIB = CallLadderPin::LIB
  TYPER_FILE = "#{LIB}/expression_typer.rb".freeze
  RUNG_DIRECTORY = "#{LIB}/call_ladder/".freeze
  RUNG_HOME = "CallLadder::"
  # The files a re-entry point or the dispatcher's interior could be called from: the engine, the plugins and the
  # examples.
  ENGINE_GLOBS = %w[lib/**/*.rb plugins/*/lib/**/*.rb examples/*/lib/**/*.rb].freeze
  # The parameter a rung function holds the typer in. The reading knows the typer by this name alone.
  TYPER = :typer
  # Calls that name the method they reach in their first argument.
  REFLECTIVE = %i[send __send__ public_send method public_method instance_method respond_to?].freeze
  # ADR-116, the #3318 cut-off: a rung calls back at most this many distinct typer methods, the scope read aside.
  CALLBACK_LIMIT = 4
  # What the frame is read through, and so no callback.
  FRAME_READ = %i[scope].freeze
  # The classes that type code. A rung module that named one could build a typer of its own and type through it,
  # past `PORT` and the cut-off.
  TYPING_CLASSES = %i[ExpressionTyper StatementEvaluator].freeze
  # The methods that type code on what they are called on: the typer's `return_type_for`, and every method of
  # `Scope` that builds one of {TYPING_CLASSES} (`type_of`, `user_method_return`, `evaluate`; the spec reads
  # `scope.rb` to keep this list whole). A rung module calls none of them on anything but its typer, where `PORT`
  # decides.
  TYPING_ENTRIES = %i[type_of return_type_for user_method_return evaluate].freeze
  # What reaches a constant by its name. A rung module names the constants it uses; through `const_get` it could reach
  # one of {TYPING_CLASSES} with no constant node to see (`Rigor::Inference.const_get(:ExpressionTyper)`,
  # `Object.const_get("Rigor::Inference::ExpressionTyper")`), and through a name it builds, any constant at all. So
  # the call is banned whatever its argument: a reading of its literal argument would miss a name that is built.
  CONSTANT_LOOKUPS = %i[const_get].freeze
  SCOPE_FILE = "lib/rigor/scope.rb"

  module_function

  # The methods of `source` (`scope.rb`) whose body builds one of {TYPING_CLASSES} with `new`.
  def typer_builders(source)
    found = []
    CallLadderPin.each_node(Prism.parse(source).value, defs: true) do |node|
      next unless node.is_a?(Prism::DefNode)

      builds = false
      CallLadderPin.each_node(node.body) do |inner|
        builds ||= inner.is_a?(Prism::CallNode) && inner.name == :new && typing_constant?(inner.receiver)
      end
      found << node.name if builds
    end
    found
  end

  # Whether `node` is a constant naming one of {TYPING_CLASSES}, written bare or as the last segment of a path.
  def typing_constant?(node)
    (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && TYPING_CLASSES.include?(node.name)
  end

  def ladder = Rigor::Inference::CallLadder

  # The typer methods a rung calls back, as the cut-off counts them: every name it calls on its typer but the scope
  # read. A public callback counts as a re-entry point does.
  def callbacks(typer_calls) = typer_calls - FRAME_READ

  # `home => RungFile` for every rung module of this checkout: each file under `call_ladder/`.
  def rung_files(root = ROOT)
    CallLadderPin.sources(root).select { |home, _source| home.start_with?(RUNG_HOME) }
                 .to_h { |home, source| [home, RungFile.new(home, source)] }
  end

  # The functions the tables give `home`: its rung's `asked_as`, then its second entries.
  def declared_entries(home, rungs: ladder::RUNGS, second_entries: ladder::SECOND_ENTRIES)
    rungs.select { |rung| rung.home == home }.flat_map(&:asked_as) +
      second_entries.select { |entry| entry.home == home }.map(&:name)
  end

  # The functions of `home` that are given the typer: its rung's entry, and each second entry that says so.
  def typer_entries(home, rungs: ladder::RUNGS, second_entries: ladder::SECOND_ENTRIES)
    rungs.select { |rung| rung.home == home }.flat_map(&:asked_as) +
      second_entries.select { |entry| entry.home == home && entry.given_typer }.map(&:name)
  end

  # The method `call` reaches: its own name, or the one a reflective call's first argument spells.
  def reached(call)
    return call.name unless REFLECTIVE.include?(call.name)

    first = call.arguments&.arguments&.first
    first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode) ? first.unescaped.to_sym : call.name
  end

  def reflective?(call) = REFLECTIVE.include?(call.name) && reached(call) != call.name

  # `[name, call]` for every call in `source` that reaches one of `names`: by name, through a reflective call
  # that spells it, or as a `&:name` block.
  def calls_reaching(source, names)
    found = []
    CallLadderPin.each_node(Prism.parse(source).value, defs: true) do |node|
      next unless node.is_a?(Prism::CallNode)

      found << [reached(node), node] if names.include?(reached(node))
      passed = block_symbol(node)
      found << [passed, node] if names.include?(passed)
    end
    found
  end

  # The name of a `&:name` block passed to `call`.
  def block_symbol(call)
    block = call.block
    passed = block.expression if block.is_a?(Prism::BlockArgumentNode)
    passed.unescaped.to_sym if passed.is_a?(Prism::SymbolNode)
  end

  # Why a call that reaches a re-entry point may not stand in `path`, or nil when it may: with no receiver in the
  # typer's own file, and on the local `typer` in a rung module.
  def reentry_breach(path, name, call)
    receiver = call.receiver
    spelled = "#{receiver&.slice}#{'.' if receiver}#{call.name}"
    if path == TYPER_FILE
      return nil if !reflective?(call) && call.name == name && (receiver.nil? || receiver.is_a?(Prism::SelfNode))

      return "#{path}: `#{spelled}` reaches `#{name}` on something other than the typer itself"
    end
    on_typer = receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == TYPER
    return nil if path.start_with?(RUNG_DIRECTORY) && on_typer && call.name == name

    "#{path}: `#{spelled}` reaches the typer's re-entry point `#{name}` outside a rung module's call on its typer"
  end

  # Every breach of the re-entry rule in `sources` (`path => source`).
  def reentry_breaches(sources, reentry: ladder::REENTRY)
    pattern = Regexp.union(reentry.map(&:to_s))
    sources.flat_map do |path, source|
      next [] unless source.match?(pattern)

      calls_reaching(source, reentry).filter_map { |name, call| reentry_breach(path, name, call) }
    end
  end

  # The calls in `source` that reach the dispatcher's interior on `MethodDispatcher`, as they are spelled.
  def interior_calls(source, interior: ladder::DISPATCHER_INTERIOR)
    calls_reaching(source, interior).filter_map do |_name, call|
      receiver = call.receiver
      constant = receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
      call.slice[/\A[^(\n]+/] if constant && receiver.slice.end_with?("MethodDispatcher")
    end
  end

  # `path => source` for the engine, the plugins and the examples.
  def engine_sources(root = ROOT)
    Dir.glob(ENGINE_GLOBS, base: root).sort.to_h { |path| [path, File.read(File.join(root, path))] }
  end

  # The comment block directly above the definition of `name` in `source`: a `def`, or an `attr_reader` that
  # names it.
  def comment_above(source, name)
    lines = source.lines
    index = lines.index { |line| line.match?(/\A\s*(?:def #{Regexp.escape(name.to_s)}\b|attr_reader .*:#{name}\b)/) }
    return nil if index.nil?

    above = lines.first(index).reverse.take_while { |line| line.match?(/\A\s*#/) }
    above.reverse.join
  end

  # The names `source` makes public by a `public :a, :b` statement.
  def made_public(source)
    found = []
    CallLadderPin.each_node(Prism.parse(source).value, defs: true) do |node|
      next unless node.is_a?(Prism::CallNode) && node.name == :public && node.receiver.nil?

      found.concat((node.arguments&.arguments || []).grep(Prism::SymbolNode).map { |symbol| symbol.unescaped.to_sym })
    end
    found
  end

  # One rung module's source, read for what it exposes and what it does with a typer.
  class RungFile
    attr_reader :home

    def initialize(home, source)
      result = Prism.parse(source)
      raise ArgumentError, result.errors.first.message if result.failure?

      @home = home
      @defs = Hash.new { |hash, name| hash[name] = [] }
      @private = []
      @parents = {}.compare_by_identity
      @nodes = []
      index(result.value, nil)
    end

    # How many methods the reading found: a reading of no code holds nothing.
    def method_count = @defs.sum { |_name, found| found.size }

    # The functions the module exposes: every `def` its `private_class_method` does not name.
    def entries = @defs.keys - @private

    # The names `private_class_method` hides that no `def` of the file has.
    def hidden_without_def = @private - @defs.keys

    # The positional parameter names of `name`, in order, or nil when the file has not exactly one such `def`.
    def parameters(name)
      definition = definition_of(name)
      return nil if definition.nil?

      list = definition.parameters
      list.nil? ? [] : (list.requireds + list.optionals).map(&:name)
    end

    # Every parameter name of `name`, of any kind.
    def every_parameter(name)
      names = []
      CallLadderPin.each_node(definition_of(name)&.parameters) { |node| names << node.name if node.respond_to?(:name) }
      names.compact
    end

    # The methods the module calls on its typer, each once.
    def typer_calls
      typer_reads.filter_map { |node| receiver_of(node)&.name }.uniq
    end

    # What the module does with its typer that the port does not allow, as messages. A typer is called (the name
    # must be in `port`), or handed on: to a function of this file whose parameter at that position is `typer`, or
    # to an entry of another rung module that is given the typer (`given`, `home => names`).
    def typer_breaches(port, given)
      typer_reads.filter_map do |node|
        call = receiver_of(node)
        if call
          "#{where(node)}: calls `typer.#{call.name}`, which is not in CallLadder::PORT" unless port.include?(call.name)
        elsif !handed_on?(node, given)
          "#{where(node)}: the typer leaves the port (#{handed_to(node)})"
        end
      end
    end

    # Reads of a scope off anything but the typer (`site.scope`), as messages.
    def foreign_scope_reads
      @nodes.grep(Prism::CallNode).filter_map do |call|
        next unless call.name == :scope && call.receiver && !typer?(call.receiver)

        "#{where(call)}: reads `#{call.slice}`; a rung reads the scope as `typer.scope`"
      end
    end

    # Where the module would type code itself rather than through its typer, as messages: a constant naming one of
    # {TYPING_CLASSES}, a call of one of {TYPING_ENTRIES} on anything but the local `typer` (a scope, `typer.scope`
    # included), and a call of one of {CONSTANT_LOOKUPS} on anything. A call counts by name, through a reflective
    # call that spells it, or as a `&:name` block.
    def typing_bypasses
      named = @nodes.select { |node| CallLadderPort.typing_constant?(node) }.map do |node|
        "#{where(node)}: names `#{node.slice}`; a rung types only through its typer"
      end
      entered = @nodes.grep(Prism::CallNode).flat_map do |call|
        [CallLadderPort.reached(call), CallLadderPort.block_symbol(call)].uniq.filter_map { |name| bypass(call, name) }
      end
      named + entered
    end

    # Why `name` is not a function of its arguments alone, as messages: it names a typer or a scope, calls
    # something with no receiver (a function of the module, a method of whatever `self` is), calls on `self` or on
    # a constant, or reads an instance, class or global variable.
    def impurities(name)
      definition = definition_of(name)
      return ["#{home}.#{name} has no single definition"] if definition.nil?

      named = every_parameter(name) & [TYPER, :scope]
      found = named.map { |parameter| "#{home}.#{name} takes `#{parameter}`" }
      CallLadderPin.each_node(definition.body) { |node| found << impurity(name, node) }
      found.compact
    end

    private

    def index(node, parent)
      @parents[node] = parent
      @nodes << node
      @defs[node.name] << node if node.is_a?(Prism::DefNode)
      @private.concat(symbols_of(node)) if node.is_a?(Prism::CallNode) && node.name == :private_class_method
      node.compact_child_nodes.each { |child| index(child, node) }
    end

    def symbols_of(call)
      (call.arguments&.arguments || []).grep(Prism::SymbolNode).map { |symbol| symbol.unescaped.to_sym }
    end

    def definition_of(name) = @defs.fetch(name, []).then { |found| found.size == 1 ? found.first : nil }

    def typer?(node) = node.is_a?(Prism::LocalVariableReadNode) && node.name == TYPER

    def typer_reads = @nodes.select { |node| typer?(node) }

    # The call `node` is the receiver of, if it is one.
    def receiver_of(node)
      parent = @parents[node]
      parent if parent.is_a?(Prism::CallNode) && parent.receiver.equal?(node)
    end

    # The call `node` is a positional argument of, with its position.
    def argument_of(node)
      list = @parents[node]
      call = @parents[list] if list.is_a?(Prism::ArgumentsNode)
      call.is_a?(Prism::CallNode) ? [call, list.arguments.index { |argument| argument.equal?(node) }] : nil
    end

    def handed_on?(node, given)
      call, position = argument_of(node)
      return false if call.nil?
      return parameters(call.name)&.at(position) == TYPER if call.receiver.nil?

      module_home = rung_home_of(call.receiver, given.keys)
      !module_home.nil? && given.fetch(module_home).include?(call.name)
    end

    # The rung module a constant names, written in full or from inside `CallLadder`.
    def rung_home_of(receiver, homes)
      return nil unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

      written = receiver.slice.delete_prefix("::")
      homes.find do |candidate|
        full = "#{CallLadderPin::NAMESPACE}::#{candidate}"
        full == written || full.end_with?("::#{written}")
      end
    end

    def handed_to(node)
      call, = argument_of(node)
      call ? "an argument of `#{call.slice[/\A[^(\n]+/]}`" : "used as #{@parents[node].type}"
    end

    def where(node)
      definition = node
      definition = @parents[definition] until definition.nil? || definition.is_a?(Prism::DefNode)
      "#{home}#{".#{definition.name}" if definition} (line #{node.location.start_line})"
    end

    # Why `call`, reaching `name`, types past the typer, or nil.
    def bypass(call, name)
      if CONSTANT_LOOKUPS.include?(name)
        return "#{where(call)}: calls `#{name}`; a rung names the constants it uses, and types only through its typer"
      end
      return unless TYPING_ENTRIES.include?(name) && !typer?(call.receiver)

      "#{where(call)}: calls `#{name}` on `#{call.receiver&.slice || 'self'}`; a rung types only through its typer"
    end

    def impurity(name, node)
      case node
      when Prism::CallNode then impure_call(name, node)
      when Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode
        "#{home}.#{name} reads `#{node.slice}`"
      end
    end

    def impure_call(name, call)
      receiver = call.receiver
      return "#{home}.#{name} calls `#{call.name}` with no receiver" if receiver.nil?
      return unless receiver.is_a?(Prism::SelfNode) || receiver.is_a?(Prism::ConstantReadNode) ||
                    receiver.is_a?(Prism::ConstantPathNode)

      "#{home}.#{name} calls `#{call.slice[/\A[^(\n]+/]}`"
    end
  end
end

# The port's examples on this checkout, shared by `spec/rigor/inference/call_ladder/port_spec.rb` and by the spec in
# the typer's mirror directory: `verify-changed` picks a spec by the `lib/` file it mirrors, and an edit to the typer
# has to meet the port as an edit to a rung module does.
RSpec.shared_examples "the port the tables declare" do
  let(:ladder) { Rigor::Inference::CallLadder }
  let(:files) { CallLadderPort.rung_files }
  let(:given) { files.keys.to_h { |home| [home, CallLadderPort.typer_entries(home)] } }
  let(:typer_source) { File.read(File.join(CallLadderPort::ROOT, CallLadderPort::TYPER_FILE)) }

  it "is read in one file under call_ladder/ for each rung whose body has moved, and there is one" do
    moved = ladder::RUNGS.map(&:home).select { |home| home.start_with?(CallLadderPort::RUNG_HOME) }

    expect(moved).not_to be_empty
    expect(files.keys).to match_array(moved)
    expect(files.values.map(&:method_count)).to all(be > 1)
  end

  it "is all a rung module calls on its typer, which leaves it only for a function that is given one" do
    breaches = files.values.flat_map { |file| file.typer_breaches(ladder::PORT, given) + file.foreign_scope_reads }

    expect(breaches).to eq([]), <<~MESSAGE
      #{breaches.join("\n")}
      A rung module calls on its typer only what CallLadder::PORT (lib/rigor/inference/call_ladder.rb) lists, hands the
      typer only to a function of its own file whose parameter there is `typer` or to another rung's entry that is
      given one, and reads the scope as `typer.scope`. A rung that needs another typer method is over the cut-off of
      ADR-116 § "Amendment, 2026-11-19 — WD12's interface": it stays in the typer, and the list is not widened.
    MESSAGE
  end

  it "is the only way a rung module types code: it names no typing class and enters no typing entry elsewhere" do
    bypasses = files.values.flat_map(&:typing_bypasses)

    expect(bypasses).to eq([]), <<~MESSAGE
      #{bypasses.join("\n")}
      A rung module types code only through the typer it is given, by what CallLadder::PORT lists. A typer it builds
      (ExpressionTyper.new, StatementEvaluator.new) or a typing entry it calls on a scope (typer.scope.type_of,
      scope.evaluate) would type past the port and past the cut-off of four callbacks.
    MESSAGE
  end

  it "has no member that no rung calls, and no rung that calls back more than four of them" do
    called = files.transform_values(&:typer_calls)
    callbacks = called.transform_values { |names| CallLadderPort.callbacks(names).size }

    expect(ladder::PORT - called.values.flatten).to eq([])
    expect(callbacks.values).to all(be <= CallLadderPort::CALLBACK_LIMIT)
    expect(ladder::PORT).to eq([*CallLadderPort::FRAME_READ, *ladder::PUBLIC_CALLBACKS, *ladder::REENTRY])
    expect(ladder::PUBLIC_CALLBACKS & ladder::REENTRY).to eq([])
  end

  # A public callback was public before any rung needed it, so it carries no mark and none is asked of it.
  it "is public on the typer and marked `@api private` but for the public callbacks, the re-entry points made " \
     "public in one statement" do
    made_for_rungs = ladder::PORT - ladder::PUBLIC_CALLBACKS
    marked = made_for_rungs.select do |name|
      CallLadderPort.comment_above(typer_source, name).to_s.include?("@api private")
    end

    expect(Rigor::Inference::ExpressionTyper.public_instance_methods(false)).to include(*ladder::PORT)
    expect(made_for_rungs).to eq([*CallLadderPort::FRAME_READ, *ladder::REENTRY])
    expect(marked).to eq(made_for_rungs)
    expect(CallLadderPort.made_public(typer_source)).to eq(ladder::REENTRY)
  end

  it "is reached through the entries the tables name: the rung's own, and its second entries" do
    files.each do |home, file|
      declared = CallLadderPort.declared_entries(home)
      loaded = Object.const_get("Rigor::Inference::#{home}")

      expect(file.entries).to match_array(declared)
      expect(file.hidden_without_def).to eq([])
      expect(loaded.singleton_class.public_instance_methods(false)).to match_array(declared)
    end
  end

  it "gives the rung's entry the site and the typer, and a second entry the typer only where its row says so" do
    aggregate_failures do
      ladder::RUNGS.select { |rung| files.key?(rung.home) }.each do |rung|
        expect(rung.asked_as.map { |name| files.fetch(rung.home).parameters(name) }).to all(eq(%i[site typer]))
      end
      ladder::SECOND_ENTRIES.each do |entry|
        file = files.fetch(entry.home)
        next expect(file.parameters(entry.name).last).to eq(CallLadderPort::TYPER) if entry.given_typer

        expect(file.impurities(entry.name)).to eq([]), "#{entry.home}.#{entry.name} is given no typer"
      end
    end
  end
end

# The re-entry rule's examples on this checkout, shared as the port's are.
RSpec.shared_examples "the re-entry points the tables declare" do
  let(:ladder) { Rigor::Inference::CallLadder }
  let(:sources) { CallLadderPort.engine_sources }

  it "are called with no receiver by the typer, on its typer by a rung module, and by nothing else" do
    breaches = CallLadderPort.reentry_breaches(sources)
    reached = sources.values_at(CallLadderPort::TYPER_FILE, *sources.keys.grep(/\A#{CallLadderPort::RUNG_DIRECTORY}/o))
                     .flat_map { |source| CallLadderPort.calls_reaching(source, ladder::REENTRY).map(&:first) }

    expect(breaches).to eq([]), <<~MESSAGE
      #{breaches.join("\n")}
      A re-entry point (CallLadder::REENTRY) runs the typer's own code inside the `type_of` walk that asked a rung, so
      only the typer and a rung module's call on the typer it was given may reach one.
    MESSAGE
    expect(ladder::REENTRY - reached).to eq([])
  end

  it "leave the dispatcher's interior to the dispatcher: neither the typer nor a rung module asks it" do
    asked = CallLadderPin.sources(CallLadderPort::ROOT)
                         .transform_values { |source| CallLadderPort.interior_calls(source) }
                         .reject { |_home, calls| calls.empty? }
    tiers = %w[composite_receiver project_patched].map { |name| "#{CallLadderPort::LIB}/method_dispatcher/#{name}.rb" }

    expect(asked).to eq({})
    expect(sources.values_at(*tiers).map { |source| CallLadderPort.interior_calls(source) })
      .to all(eq(%w[MethodDispatcher.resolve]))
  end
end
