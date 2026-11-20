# frozen_string_literal: true

require "prism"
require "rigor/inference/call_ladder"

# The Prism reading behind `spec/rigor/inference/call_ladder_spec.rb`: what each place of the call ladder asks,
# read from the code, beside what the tables of `Rigor::Inference::CallLadder` say it asks. See the spec's header
# for the rule and for what the reading cannot see.
#
# Everything a call is spelled with comes from the tables: a rung's `home` and `asked_as`, an entry's `home`,
# `written_in` and `ahead`, an exception row's `written_in` and gates, a second entry's `home` and `name`. Nothing
# here names a method of the typer, so a rung whose body moves changes its row and not this file.
module CallLadderPin
  NAMESPACE = "Rigor::Inference"
  LIB = "lib/rigor/inference"
  ROOT = File.expand_path("../..", __dir__)

  # A sequence the spec holds: an entry's own methods (`exception` nil), or a branch an exception row names.
  Place = Data.define(:name, :entry, :exception)

  # One value a method can answer with. `node` is the call, or the node that stands where the reading wanted a
  # call. `site` orders the answers: the offset of the `return` argument or last expression the method answers it
  # from, then the side of each `||` on the way down to it. `guard` is the predicate of the `if` the answer stands
  # directly under (`return x if test`, or `x if test` in last position), when it stands under one.
  Answer = Data.define(:node, :site, :guard)

  module_function

  # The reading of this checkout against the tables the engine ships.
  def reading(root = ROOT)
    ladder = Rigor::Inference::CallLadder
    Reading.new(entries: ladder::ENTRIES, rungs: ladder::RUNGS, exceptions: ladder::EXCEPTIONS,
                second_entries: ladder::SECOND_ENTRIES, sources: sources(root))
  end

  # `home => source` for every file a sequence can be written in: the typer, the modules moved out of it under
  # `expression_typer/`, and each rung module under `call_ladder/`.
  def sources(root)
    paths = ["#{LIB}/expression_typer.rb"] + Dir.glob("#{LIB}/{expression_typer,call_ladder}/*.rb", base: root)
    paths.sort.to_h { |path| [home_of(path), File.read(File.join(root, path))] }
  end

  # `lib/rigor/inference/call_ladder/user_method.rb` is the file of `CallLadder::UserMethod`.
  def home_of(path)
    segments = path.delete_prefix("#{LIB}/").delete_suffix(".rb").split("/")
    segments.map { |segment| segment.split("_").map(&:capitalize).join }.join("::")
  end

  # Every node under `node`, itself included, in source order. A nested `def` is another method's code, so it
  # is left out unless `defs` is set.
  def each_node(node, defs: false)
    pending = [node].compact
    until pending.empty?
      current = pending.shift
      yield current
      children = current.compact_child_nodes
      pending.unshift(*(defs ? children : children.grep_v(Prism::DefNode)))
    end
  end

  # The order's three tables, and the five of the port (`spec/support/call_ladder_port.rb` reads those).
  TABLES = %w[RUNGS ENTRIES EXCEPTIONS PORT PUBLIC_CALLBACKS REENTRY SECOND_ENTRIES DISPATCHER_INTERIOR].freeze

  # What in `source` reads the tables: a `require` of their file, or one of them named. Inside `CallLadder`
  # (`inside`) a table can be named bare; elsewhere only `RUNGS` is a name no other constant of `lib/` has.
  def table_reads(source, inside: false)
    found = []
    each_node(Prism.parse(source).value, defs: true) do |node|
      case node
      when Prism::ConstantPathNode then found << node.slice if table?(node.slice.delete_prefix("::"))
      when Prism::ConstantReadNode then found << node.slice if node.name == :RUNGS || (inside && table?(node.slice))
      when Prism::CallNode then found << node.slice if requires_tables?(node)
      end
    end
    found
  end

  def table?(name) = TABLES.any? { |table| name == table || name.end_with?("CallLadder::#{table}") }

  def requires_tables?(call)
    return false unless %i[require require_relative].include?(call.name) && call.receiver.nil?

    path = call.arguments&.arguments&.first
    path.is_a?(Prism::StringNode) && path.unescaped.match?(%r{(\A|/)call_ladder\z})
  end

  # `[path, read]` for everything under `lib/` that reads the tables, their own file aside.
  def engine_reads(root = ROOT)
    Dir.glob("lib/**/*.rb", base: root).sort.flat_map do |path|
      next [] if path == "#{LIB}/call_ladder.rb"

      source = File.read(File.join(root, path))
      next [] unless source.match?(/RUNGS|CallLadder|call_ladder/)

      table_reads(source, inside: path.start_with?("#{LIB}/call_ladder/")).map { |read| [path, read] }
    end
  end

  # What one method can answer with, in the order it answers.
  #
  # An answer is the argument of a `return` or the method's last expression, followed through `a || b`, a
  # parenthesis, an `if` / `else` in last position, and a local back to every value the method assigns it. A call
  # reached that way is an answer; its own receiver and arguments are not. A value that is no call (`nil`, a
  # constant, a parameter) answers nothing a rung could. Any other shape (`&&`, `case`, `rescue`, a multiple
  # assignment) is kept as an answer whose node is not a call, so the place it sits in fails rather than
  # passes unread.
  class Answers
    VALUES = [
      Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SymbolNode, Prism::IntegerNode, Prism::StringNode,
      Prism::SelfNode, Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::ReturnNode
    ].freeze
    WRITES = [
      Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
      Prism::LocalVariableOperatorWriteNode
    ].freeze

    # In the order the method answers from them.
    attr_reader :list

    def initialize(def_node)
      @body = def_node.body
      @parameters = []
      CallLadderPin.each_node(def_node.parameters) { |node| @parameters << node.name if node.respond_to?(:name) }
      @writes = Hash.new { |hash, name| hash[name] = [] }
      @resolving = []
      @found = []
      CallLadderPin.each_node(@body) { |node| note_write(node) }
      returns(@body, nil)
      last = @body.is_a?(Prism::StatementsNode) ? @body.body.last : @body
      terminals(last, [last.location.start_offset], nil) if last
      @list = @found.sort_by { |answer| [answer.site, answer.node.location.start_offset] }.uniq(&:node)
    end

    # Whether the method writes its calls in another order than it answers from them. A rung asked ahead of the
    # one above it has still run first, whichever answer is returned first.
    def out_of_order?
      list.map(&:node) != list.sort_by { |answer| answer.node.location.start_offset }.map(&:node)
    end

    private

    def note_write(node)
      case node
      when *WRITES then @writes[node.name] << node.value
      when Prism::LocalVariableTargetNode then @writes[node.name] << node
      end
    end

    # Every `return` of the method, with the predicate of the `if` it stands directly under.
    def returns(node, guard)
      case node
      when nil, Prism::DefNode, Prism::LambdaNode then nil
      when Prism::ReturnNode
        (node.arguments&.arguments || []).each { |value| terminals(value, [value.location.start_offset], guard) }
      when Prism::IfNode
        (node.statements&.body || []).each { |statement| returns(statement, node.predicate) }
        returns(node.subsequent, nil)
      else node.compact_child_nodes.each { |child| returns(child, nil) }
      end
    end

    # A call is an answer, and so is any node no arm below reads: {Reading} turns that one into a failure.
    def terminals(node, site, guard)
      case node
      when nil, *VALUES then nil
      when Prism::OrNode
        terminals(node.left, [*site, 0], guard)
        terminals(node.right, [*site, 1], guard)
      when Prism::StatementsNode then terminals(node.body.last, site, guard)
      when Prism::ParenthesesNode then terminals(node.body, site, guard)
      when Prism::ElseNode then terminals(node.statements, site, guard)
      when Prism::IfNode
        terminals(node.statements, site, node.predicate)
        terminals(node.subsequent, site, nil)
      when Prism::LocalVariableReadNode then local(node, site, guard)
      when *WRITES then terminals(node.value, site, guard)
      else @found << Answer.new(node: node, site: site, guard: guard)
      end
    end

    # A local answers what the method assigned it. A parameter the method never assigns answers no call, and a
    # local with no assignment the reading can see is kept as it stands, unread.
    def local(node, site, guard)
      name = node.name
      values = @writes[name]
      return if @resolving.include?(name) || (values.empty? && @parameters.include?(name))
      return @found << Answer.new(node: node, site: site, guard: guard) if values.empty?

      @resolving.push(name)
      values.each { |value| terminals(value, site, guard) }
      @resolving.pop
    end
  end

  # The tables read against the sources. `sources` is `home => Ruby source`.
  class Reading
    # `second_entries` are rows of `CallLadder::SECOND_ENTRIES`, which only {#stray_sequences} reads.
    def initialize(entries:, rungs:, exceptions:, sources:, second_entries: [])
      @entries = entries
      @rungs = rungs
      @exceptions = exceptions
      @second_entries = second_entries
      @defs = sources.transform_values { |source| defs_in(source) }
    end

    def places
      @entries.flat_map do |entry|
        [Place.new(name: entry.name, entry: entry, exception: nil)] +
          branches(entry).map { |row| Place.new(name: row.name, entry: entry, exception: row) }
      end
    end

    # What the tables say `place` asks: what answers ahead of its ladder, then its entry's rungs in order, less
    # the ones an exception row omits, each as `[:ahead | :rung | :gate, name]`.
    def expected(place)
      rows = exceptions_over(place)
      omitted = rows.flat_map(&:omits)
      gated = rows.flat_map { |row| row.gates.map(&:rung) }
      asked = @rungs.select { |rung| rung.asked_by.include?(place.entry.name) && !omitted.include?(rung.name) }
      rungs = asked.map { |rung| [gated.include?(rung.name) ? :gate : :rung, rung.name] }
      place.entry.ahead.map { |name| [:ahead, name] } + rungs
    end

    # What the code of `place` can answer with, in order, in the same form. Anything else it can answer with is
    # an item of another kind (`:undeclared`, `:unreadable`, `:order`, `:missing`), so that the comparison
    # with {#expected} fails and shows it.
    def written(place)
      entry = place.entry
      main = items(entry, entry.written_in.first, nil, [])
      return without_branches(main) if place.exception.nil?

      branch = place.exception.written_in
      cut = main.index([:branch, branch])
      return [[:missing, "#{entry.written_in.first} does not return through #{branch}"]] if cut.nil?

      without_branches(main.first(cut)) + items(entry, branch, place.exception, [])
    end

    # `[home, method, rung]` for each rung a place's method asks somewhere other than in what it answers with:
    # in a condition, an argument, or a statement whose value it drops.
    def hidden_asks
      place_methods.flat_map do |home, name|
        definition = definition_of(home, name)
        next [] if definition.nil?

        answers = Answers.new(definition).list.map(&:node)
        hidden = rung_calls(definition, home).reject { |call, _rung| answers.any? { |node| node.equal?(call) } }
        hidden.map { |_call, rung| [home, name, rung.name] }
      end
    end

    # `[home, method, asks]` for each method outside the places that asks the ladder for two or more different
    # things: a sequence the tables do not hold. A rung counts by its name, asked by its own entry or by a second
    # entry of its module, and so does a method a place is written in, since a continuation is the rungs it holds.
    def stray_sequences
      methods = @defs.flat_map { |home, by_name| by_name.flat_map { |name, found| found.map { [home, name, it] } } }
      methods.filter_map do |home, name, definition|
        next if place_methods.include?([home, name])

        asks = ladder_asks(definition, home).uniq
        [home, name, asks] if asks.size > 1
      end
    end

    # How many methods the reading found in each source: a reading of no code holds nothing.
    def method_counts = @defs.transform_values { |by_name| by_name.sum { |_name, found| found.size } }

    def rung(name) = @rungs.find { |row| row.name == name }

    # The exception rows `place` is held to: the ones over its whole entry, and its own when it is a branch.
    def exceptions_over(place)
      @exceptions.select { |row| row.entry == place.entry.name && row.written_in.nil? } + [place.exception].compact
    end

    private

    def defs_in(source)
      result = Prism.parse(source)
      raise ArgumentError, result.errors.first.message if result.failure?

      found = Hash.new { |hash, name| hash[name] = [] }
      walk_defs(result.value, found)
      found
    end

    def walk_defs(node, found)
      found[node.name] << node if node.is_a?(Prism::DefNode)
      node.compact_child_nodes.each { |child| walk_defs(child, found) }
    end

    def branches(entry) = @exceptions.select { |row| row.entry == entry.name && row.written_in }

    # A branch is where a sequence leaves its method, not something it asks.
    def without_branches(sequence) = sequence.reject { |item| item.first == :branch }

    # `[home, method]` of every method a place is written in.
    def place_methods
      @place_methods ||= @entries.flat_map do |entry|
        (entry.written_in + branches(entry).map(&:written_in)).map { |name| [entry.home, name] }
      end
    end

    # The one `def` of `name` in `home`'s file, or nil when there is none or more than one.
    def definition_of(home, name)
      definitions = @defs.fetch(home, {}).fetch(name, [])
      definitions.size == 1 ? definitions.first : nil
    end

    def items(entry, name, exception, expanding)
      definition = definition_of(entry.home, name)
      return [[:missing, "#{entry.home} has no single method #{name}"]] if definition.nil?

      answers = Answers.new(definition)
      sequence = answers.list.flat_map { |answer| item(answer, entry, exception, [*expanding, name]) }
      return sequence unless answers.out_of_order?

      [[:order, "#{name} asks rungs in one order and answers from them in another"], *sequence]
    end

    def item(answer, entry, exception, expanding)
      node = answer.node
      return [[:unreadable, "#{node.type} at line #{node.location.start_line}"]] unless call?(node)

      rung = rung_of(node, entry.home)
      return [[:rung, rung.name]] if rung

      (node.receiver.nil? && own_item(answer, entry, exception, expanding)) || [[:undeclared, spelling(node)]]
    end

    # A call with no receiver that is not a rung: a gate's answer, what answers ahead of the ladder, the method
    # the sequence continues in, or the branch an exception row names.
    def own_item(answer, entry, exception, expanding)
      name = answer.node.name
      gate = exception&.gates&.find { |row| row.answer == name && tested?(answer.guard, row, entry.home) }
      return [[:gate, gate.rung]] if gate
      return [[:ahead, name]] if entry.ahead.include?(name)
      return items(entry, name, exception, expanding) if continuation?(entry, name, expanding)

      [[:branch, name]] if branches(entry).any? { |row| row.written_in == name }
    end

    def continuation?(entry, name, expanding) = entry.written_in.drop(1).include?(name) && !expanding.include?(name)

    def call?(node) = node.is_a?(Prism::CallNode)

    def spelling(call) = [call.receiver&.slice, call.name].compact.join(".")

    # Whether `guard`, the predicate a `return` stands under, is the gate of `row`, spelled at its rung's home.
    def tested?(guard, row, file_home)
      gated = rung(row.rung)
      call?(guard) && guard.name == row.ask && !gated.nil? && at_home?(guard.receiver, gated.home, file_home)
    end

    # The rung `call` asks, read from `file_home`'s file: by one of the rung's own spellings, or through a method
    # of that file whose whole body is one such call (a typer method that only wraps `MethodDispatcher.dispatch`).
    def rung_of(call, file_home, wrapped: false)
      direct = @rungs.find { |rung| rung.asked_as.include?(call.name) && at_home?(call.receiver, rung.home, file_home) }
      return direct if direct || wrapped || call.receiver

      body = definition_of(file_home, call.name)&.body
      only = body.body.first if body.is_a?(Prism::StatementsNode) && body.body.size == 1
      call?(only) ? rung_of(only, file_home, wrapped: true) : nil
    end

    # With no receiver, or on `self`, a call is a method of the file it is written in. On a constant it is a
    # method of whatever that constant names from `Rigor::Inference`, however much of the path is written.
    def at_home?(receiver, rung_home, file_home)
      case receiver
      when nil, Prism::SelfNode then rung_home == file_home
      when Prism::ConstantReadNode, Prism::ConstantPathNode then names?(receiver, rung_home)
      else false
      end
    end

    def names?(constant, home)
      written = constant.full_name.delete_prefix("::")
      full = "#{NAMESPACE}::#{home}"
      full == written || full.end_with?("::#{written}")
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
      false
    end

    # `[call, rung]` for every call in `definition` that asks a rung, wherever it stands.
    def rung_calls(definition, home)
      found = []
      CallLadderPin.each_node(definition.body) do |node|
        rung = rung_of(node, home) if call?(node)
        found << [node, rung] if rung
      end
      found
    end

    # What `definition` asks of the ladder, call by call: a rung, by its name, or a method a place of this file is
    # written in, by the method's.
    def ladder_asks(definition, home)
      found = []
      CallLadderPin.each_node(definition.body) do |node|
        next unless call?(node)

        rung = rung_of(node, home) || second_entry_rung(node, home)
        place = node.receiver.nil? && place_methods.include?([home, node.name])
        found << (rung ? rung.name : node.name) if rung || place
      end
      found
    end

    # The rung whose module `call` asks through one of its second entries, spelled as a rung's own entry is: a
    # rung's gate and its positional entry are parts of that rung. Only the stray check reads this. A place's
    # method may test a gate where it does not answer with it (the splat index read does), so {#hidden_asks}
    # counts a rung's own entry alone.
    def second_entry_rung(call, file_home)
      row = @second_entries.find { |entry| entry.name == call.name && at_home?(call.receiver, entry.home, file_home) }
      row && @rungs.find { |rung| rung.home == row.home }
    end
  end

  # What a failure of the pin tells its reader to do. Each difference between a place's code and its tables gets
  # a line that names the edit which settles it, in the code or in `lib/rigor/inference/call_ladder.rb`.
  module Advice
    TABLES = "CallLadder (lib/rigor/inference/call_ladder.rb)"
    SHAPES = "a `return`, the last expression, `||`, parentheses, `if` / `else` and the locals they read"

    module_function

    # The message for `place`, or nil when its code and its tables agree.
    def place(reading, place)
      expected = reading.expected(place)
      written = reading.written(place)
      return nil if written == expected

      lines = (written - expected).map { |item| unexpected(item, reading, place) } +
              (expected - written).map { |item| absent(item, reading, place) }
      lines << reordered if lines.empty?
      [heading(place, written, expected), *lines.map { |line| "- #{line}" }].join("\n")
    end

    def heading(place, written, expected)
      methods = place.exception&.written_in || place.entry.written_in.join(", ")
      "The `#{place.name}` sequence (#{place.entry.home}: #{methods}) is not the one #{TABLES} gives it.\n  " \
        "code asks:   #{written.map { |item| label(item) }.join(', ')}\n  " \
        "tables give: #{expected.map { |item| label(item) }.join(', ')}"
    end

    def label((kind, name))
      { rung: name.to_s, gate: "#{name} (through its gate)", ahead: "#{name} (ahead)",
        undeclared: "#{name} (no row)" }.fetch(kind) { "(#{kind}: #{name})" }
    end

    # Something the code answers with that the tables do not give the place.
    def unexpected((kind, name), reading, place)
      case kind
      when :rung, :gate then not_given(kind, name, reading, place)
      when :undeclared then undeclared(name, place)
      when :unreadable
        "The reading cannot follow #{name}. It follows #{SHAPES}. Write the answer in one of those shapes, or " \
        "teach `CallLadderPin::Answers` the new one."
      when :order
        "#{name}. Keep each `x = rung(…)` directly above its `return x if x`: a rung asked early has already run."
      else "#{name}. Correct `written_in` (or `home`) in #{TABLES}."
      end
    end

    def not_given(kind, name, reading, place)
      rows = reading.exceptions_over(place)
      omitting = rows.find { |row| row.omits.include?(name) }
      return omitted(name, omitting) if omitting
      return gate_mismatch(kind, name) if kind == :gate || rows.flat_map(&:gates).any? { |gate| gate.rung == name }

      "`#{name}` is asked here, and its row in RUNGS does not give it to `#{place.entry.name}`. Add " \
        "`#{place.entry.name}` to the row's `asked_by`, or take the call out."
    end

    def omitted(name, row)
      issue = " (##{row.issue})" if row.issue
      "`#{name}` is asked here, and the exception row `#{row.name}` says this place leaves it out#{issue}. If the " \
        "code is right, delete that row."
    end

    def gate_mismatch(kind, name)
      "`#{name}` is asked #{kind == :gate ? 'through its gate' : 'as the rung'} here, and the exception rows over " \
        "this place say the opposite. Change the code, or the row's `gates`."
    end

    def undeclared(name, place)
      entry = place.entry
      "`#{name}` can answer here, and the tables do not know it. If it is a rung, add its row to RUNGS at its " \
        "position, with `#{entry.name}` in `asked_by`. If the sequence continues in it, add it to `written_in` of " \
        "ENTRIES' `#{entry.name}`. If it answers ahead of the ladder and is no rung, add it to that entry's `ahead`. " \
        "`ahead` takes the name of a method of #{entry.home}'s own file called with no receiver, so an answer on " \
        "another receiver (`Type::Combinator.untyped`) cannot be listed: give it a method there, or keep it out of " \
        "what the place answers with."
    end

    # Something the tables give the place that its code does not answer with.
    def absent((kind, name), reading, place)
      entry = place.entry
      case kind
      when :ahead then "`#{name}` no longer answers ahead of the ladder here. Take it out of the entry's `ahead`."
      when :gate
        gate = reading.exceptions_over(place).flat_map(&:gates).find { |row| row.rung == name }
        "`#{name}` is to be asked through its gate here: test `#{gate.ask}` and answer `#{gate.answer}` where it holds."
      else
        "`#{name}` is not asked here, and its row in RUNGS gives it to `#{entry.name}`. Ask it, as " \
        "`#{spelling(reading.rung(name), entry)}`, at its place in the rows' order. If leaving it out is a defect " \
        "to fix later, add a row to EXCEPTIONS that omits it and names the issue. If `#{entry.name}` should not " \
        "ask it, take the entry out of the row's `asked_by`."
      end
    end

    def spelling(rung, entry)
      rung.home == entry.home ? "#{rung.asked_as.first}(…)" : "#{rung.home}.#{rung.asked_as.last}(…)"
    end

    def reordered
      "The same answers come in another order than the rows of RUNGS. Reorder the code. If the order itself is " \
        "to change, reorder the rows, with docs/internal-spec/inference-engine.md § \"The call ladder\"."
    end

    # The message for the rungs {Reading#hidden_asks} found.
    def hidden(found)
      found.map do |home, name, rung|
        "#{home}##{name} asks `#{rung}` where it does not answer with it (a condition, an argument, a dropped " \
          "value). A place asks a rung only as an answer: `x = rung(…)` above `return x if x`, or a side of the " \
          "last `||`."
      end.join("\n")
    end

    # The message for the sequences {Reading#stray_sequences} found.
    def strays(found)
      found.map do |home, name, asks|
        "#{home}##{name} asks #{asks.join(', ')}: a sequence outside the places #{TABLES} names. If it continues " \
          "an entry's sequence, add it to that entry's `written_in`. If it is a sequence of its own, it needs an " \
          "entry in ENTRIES (or an exception row with `written_in`) and the rows' `asked_by`. Otherwise ask one " \
          "thing of the ladder there."
      end.join("\n")
    end
  end
end

# The pin itself, shared by the spec of the tables and by a spec under `expression_typer/`: `verify-changed` picks
# a spec by the `lib/` file it mirrors, and an edit to either side of the pin has to run it.
RSpec.shared_examples "the call ladder the tables declare" do
  let(:reading) { CallLadderPin.reading }

  it "is read in four places: the methods of each entry, and the branch a splat index read takes" do
    expect(reading.places.map(&:name)).to eq(%i[call index_read splat_index_read send_target])
    expect(reading.method_counts.fetch("ExpressionTyper")).to be > 100
  end

  it "answers in each place from what the tables give it, in their order, and from nothing else" do
    aggregate_failures do
      reading.places.each do |place|
        expect(reading.written(place)).to eq(reading.expected(place)), CallLadderPin::Advice.place(reading, place)
      end
    end
  end

  it "asks a rung in those methods only where it answers with it" do
    hidden = reading.hidden_asks

    expect(hidden).to eq([]), CallLadderPin::Advice.hidden(hidden)
  end

  it "writes no sequence of two or more rungs anywhere else" do
    strays = reading.stray_sequences

    expect(strays).to eq([]), CallLadderPin::Advice.strays(strays)
  end
end
