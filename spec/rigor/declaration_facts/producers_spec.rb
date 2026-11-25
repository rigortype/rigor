# frozen_string_literal: true

require "spec_helper"
require "digest"
require "tmpdir"
require "yaml"

# #1507 — ADR-119 WD6's producer tripwire (proposed). `DeclarationProducerScan` (`spec/support/
# declaration_fact_sources.rb`) parses every Ruby file under `lib/` and `plugins/*/lib/` with Prism and marks each
# method, or class or module body, that decides what a declaration is: rules (i)–(v) and the collector rule in its
# header. The set is compared with `producers.yml`. A new producer, even a new method in a listed file, fails until it
# is recorded with a reason that says what it computes and why it does not go through `DeclarationWalk::Context` or
# `ModuleFunctionState`. `RIGOR_REGENERATE_GATES=1` records new entries as `TODO`, which fails until justified;
# entries present when the tripwire landed are `grandfathered`, and that list is closed: its size and a digest of its
# keys are pinned here, so marking a new entry `grandfathered` fails too.
#
# The tripwire lists scopes, not the code in them. A new `when` arm, or any new producer code, inside a method or body
# already listed is by design not a new entry: that scope is already a producer under review.
#
# Threat model: the tripwire catches a producer added by accident in the codebase's normal styles, not a deliberate
# evasion. It does not see dispatch on `node.class.name` or other strings, on `Prism::Node#type` through a variable,
# `Prism.const_get(:ClassNode)`, duck typing (`respond_to?(:superclass)`), a keyword spelled as a String, a constant
# reached through a variable or `const_get`, a collector subclassed through a variable or `Class.new`, or rule (v)'s
# writes outside the files `DeclarationWriterScan::SOURCES` lists, through a local alias of a parameter, through
# `...` forwarding, into a parameter handed to a writer in another file, or from a method reached only through
# `send`, a block handed to another file, or an entry point that is neither a root of its file in that table nor
# called from another covered file on the file's module, spelled as its full name or a trailing part of it
# (`ScopeIndexer.x`, `Inference::ScopeIndexer.x`; an alias constant spelled otherwise is not seen). A module that
# leaves a listed file is followed only once it has a row of its own. Plugin specs and demo apps are not scanned.
# The list freezes the set and certifies nothing about how an entry computes its context.
RSpec.describe "Declaration producers" do
  let(:snapshot) { File.join(__dir__, "producers.yml") }
  # The closed grandfathered list. Lower it when an entry goes; never raise it for a new producer.
  # Moves so far: 367 → 366 (#3014), when `concern_module_body?` stopped deriving a declaration context and
  # became a consumer. Name the entry and the reason here, since the pin itself carries no history.
  # Digest change, count still 366 (#3301): the grandfathered key
  # `lib/rigor/analysis/check_rules.rb#Rigor::Analysis::CheckRules.visibility_reduced?` became
  # `lib/rigor/analysis/check_rules/override_visibility.rb#Rigor::Analysis::CheckRules::OverrideVisibility#visibility_reduced?`
  # when the method moved; the method itself was not renamed.
  # Digest change, count still 366 (#3288): five grandfathered keys moved from `lib/rigor/inference/scope_indexer.rb#
  # Rigor::Inference::ScopeIndexer#` to `lib/rigor/inference/scope_indexer/node_propagation.rb#
  # Rigor::Inference::ScopeIndexer::NodePropagation#`: `propagate`, `propagate_call`, `propagate_end_body`,
  # `propagate_if_branches` and `propagate_unless_branches`; none was renamed.
  let(:grandfathered_pin) do
    { count: 366, digest: "b596f2681627bd2be74ac7e0ff8b1a4626264e00f30d0a653bdee25be8140e3a" }
  end

  define_method(:found) do |parsed = DeclarationFactSources.parsed_under|
    DeclarationProducerScan.producers(parsed)
  end

  define_method(:listed) do |recorded|
    recorded.flat_map { |path, entry| entry.fetch("producers").keys.map { |scope| "#{path}##{scope}" } }
  end

  define_method(:tripwire_problems) do |found, listed|
    (found.keys - listed).sort.map { |key| "#{key}: a producer (#{found[key].join(', ')}), not in producers.yml" } +
      (listed - found.keys).sort.map { |key| "#{key}: in producers.yml but no longer a producer" }
  end

  define_method(:grandfathered) do |recorded|
    keys = recorded.flat_map do |path, entry|
      entry.fetch("producers").filter_map { |scope, reason| "#{path}##{scope}" if reason == "grandfathered" }
    end.sort
    { count: keys.size, digest: Digest::SHA256.hexdigest(keys.join("\n")) }
  end

  define_method(:unjustified) do |recorded|
    recorded.flat_map do |path, entry|
      notes = [["#{path} computes", entry["computes"]]] +
              entry.fetch("producers").map { |scope, reason| ["#{path}##{scope}", reason] }
      notes.select { |_, text| text.to_s.strip.empty? || text.to_s.strip == "TODO" }.map(&:first)
    end
  end

  it "lists exactly the producers the tree has" do
    current = found
    if DeclarationFactSources.regenerate?
      File.write(snapshot, DeclarationFactSources.regenerate_producers_text(File.read(snapshot), current.keys))
    end

    problems = tripwire_problems(current, listed(YAML.load_file(snapshot)))
    expect(problems).to eq([]), "#{problems.join("\n")}\nRecord each new producer in producers.yml with a reason, or " \
                                "move it onto DeclarationWalk::Context / ModuleFunctionState. " \
                                "#{DeclarationFactSources::REGENERATE_ENV}=1 adds the entries as TODO."
  end

  # YAML ends a plain scalar at a `#` that follows whitespace, so `issue #1984` loads as the text before the hash, and
  # a comment after a quoted value is text the reader drops. The check reads the Psych AST: a scalar whose source,
  # after its end position, continues with `#` is flagged. A folded block's content is not a scalar's end, so a `: `
  # or ` #` inside it is not flagged.
  def comment_after_scalars(text)
    lines = text.lines
    flagged = []
    visit = lambda do |node|
      if node.is_a?(Psych::Nodes::Scalar)
        rest = lines.fetch(node.end_line, "")[node.end_column..].to_s
        flagged << node.value if rest.match?(/\A\s*#/)
      end
      node.children&.each(&visit)
    end
    visit.call(Psych.parse(text))
    flagged
  end

  it "writes every reason so that YAML loads it whole" do
    cut = comment_after_scalars(File.read(snapshot))

    expect(cut).to eq([]),
                   "These scalars in producers.yml are cut or followed by a comment at ` #`. Quote or fold them:\n" \
                   "#{cut.join("\n")}"
  end

  # Fixtures for the four shapes the AST check decides: each cut shape must be reported, and the folded block must not.
  describe "the comment-after-scalar check" do
    def fixture(body)
      "k:\n#{body}"
    end

    it "reports a value preceded by a tab before the hash" do
      expect(comment_after_scalars(fixture("  v: reason\t#1984\n"))).to eq(["reason"])
    end

    it "reports the continuation line of a plain value that holds the hash" do
      expect(comment_after_scalars(fixture("  v: first part\n    second #1984\n"))).to eq(["first part second"])
    end

    it "reports a quoted value followed by a comment" do
      expect(comment_after_scalars(fixture("  v: 'reason' # note\n"))).to eq(["reason"])
    end

    it "does not report a folded block whose content holds `: ` and ` #`" do
      expect(comment_after_scalars(fixture("  computes: >-\n    a: b #1\n    c\n"))).to eq([])
    end
  end

  it "justifies every file and entry" do
    missing = unjustified(YAML.load_file(snapshot))

    expect(missing).to eq([]), "Replace TODO in producers.yml: say what each file computes, and why each entry " \
                               "computes a declaration context itself.\n#{missing.join("\n")}"
  end

  # Rule (v) follows only the files its table lists, each from its own roots, and skips a root or a file it does not
  # find. A row whose file was renamed, or whose root or module moved to another file, would follow less, and the
  # list above would pass again once the entries it stopped finding were dropped from producers.yml.
  it "follows every rule (v) file from roots that are still there" do
    problems = DeclarationWriterScan.source_problems(DeclarationFactSources.parsed_under)

    expect(problems).to eq([]), "#{problems.join("\n")}\nRule (v) follows less than DeclarationWriterScan::SOURCES " \
                                "says. Give a root or a module that moved to the row of the file that now " \
                                "defines it (a new file is a new row), and fix or drop the row of a file that is gone."
  end

  it "keeps the grandfathered list closed" do
    actual = grandfathered(YAML.load_file(snapshot))

    expect(actual).to eq(grandfathered_pin),
                      "The grandfathered entries in producers.yml changed. A new producer is not grandfathered: give " \
                      "it a reason of its own. Only when a grandfathered entry was removed or renamed, set " \
                      "grandfathered_pin in producers_spec.rb to #{actual}; that edit is the review point."
  end

  describe "the tripwire itself" do
    def producers_of(source, path = "lib/rigor/probe.rb")
      DeclarationProducerScan.producers(path => Prism.parse(source).value)
                             .transform_keys { |key| key.split("#", 2).last }
    end

    it "marks a new method in a listed file, not only a new file" do
      source = <<~RUBY
        module Rigor
          module ScopeIndexer
            def new_walk(node)
              case node
              when Prism::ClassNode then 1
              end
            end
          end
        end
      RUBY

      expect(producers_of(source, "lib/rigor/inference/scope_indexer.rb"))
        .to eq("Rigor::ScopeIndexer#new_walk" => ["Prism::ClassNode"])
    end

    it "marks node-type symbols, keyword symbols, visitor hooks and same-file constants" do
      source = <<~RUBY
        class Probe < Prism::Visitor
          BODIES = [Prism::SingletonClassNode].freeze
          # Prism::ModuleNode in a comment
          def by_type(node) = node.type == :class_node
          def by_keyword(node) = node.name == :prepend
          def by_constant(node) = BODIES.include?(node.class)
          def by_label = call(include: true)
          def visit_module_node(node) = super
          define_method(:by_block) { |node| node.is_a?(Prism::ModuleNode) }
        end
      RUBY

      expect(producers_of(source))
        .to eq("Probe" => ["Prism::SingletonClassNode"], "Probe#by_type" => [":class_node"],
               "Probe#by_keyword" => [":prepend"], "Probe#by_constant" => ["Probe::BODIES (a constant built from one)"],
               "Probe#visit_module_node" => [":visit_module_node (a Prism::Visitor hook)"],
               "Probe#by_block" => ["Prism::ModuleNode"])
    end

    it "skips a keyword listed among Array or String mutators, and resolves a constant from another file" do
      parsed = {
        "lib/rigor/a.rb" => Prism.parse("module Rigor; MUTATORS = %i[push prepend unshift].freeze; " \
                                        "BODIES = [Prism::ClassNode].freeze; end").value,
        "lib/rigor/b.rb" => Prism.parse("module Rigor; class B; def f(n) = BODIES.include?(n.class) && " \
                                        "MUTATORS.include?(n.name); end; end").value
      }

      expect(DeclarationProducerScan.producers(parsed))
        .to eq("lib/rigor/a.rb#Rigor" => ["Prism::ClassNode"],
               "lib/rigor/b.rb#Rigor::B#f" => ["Rigor::BODIES (a constant built from one)"])
    end

    it "marks a collector from its include statement, whatever it names" do
      source = "module Rigor; module Inference; module DeclarationWalk; class Q; include Collector; " \
               "def on_def(_node, _context) = 1; end; end; end; end"

      expect(producers_of(source))
        .to eq("Rigor::Inference::DeclarationWalk::Q" => ["include DeclarationWalk::Collector"])
    end

    it "marks, by rule (v), a writer into a parameter reachable from index, directly or by delegation" do
      source = <<~RUBY
        module Rigor
          module ScopeIndexer
            def index(root) = walk(root, {})
            def walk(root, acc) = record(acc, root)
            def record(table, root) = (table[root] ||= []) << root
            def unreached(table) = table[:x] = 1
            def reader(table) = table[:x]
          end
        end
      RUBY

      expect(producers_of(source, DeclarationProducerScan::RULE_V_FILE).keys)
        .to eq(%w[Rigor::ScopeIndexer#walk Rigor::ScopeIndexer#record])
    end

    it "follows rule (v) through add?, a *rest, a **rest and a *splat" do
      source = <<~RUBY
        module Rigor
          module ScopeIndexer
            def index(root, seen) = spread(root, seen)
            def spread(*args) = mark(*args)
            def mark(root, seen) = seen.add?(root)
            def accumulate_project_index(acc, path) = keep(path: path, into: acc)
            def keep(path:, **rest) = rest[:into] << path
          end
        end
      RUBY

      expect(producers_of(source, DeclarationProducerScan::RULE_V_FILE).keys)
        .to contain_exactly("Rigor::ScopeIndexer#index", "Rigor::ScopeIndexer#spread", "Rigor::ScopeIndexer#mark",
                            "Rigor::ScopeIndexer#accumulate_project_index", "Rigor::ScopeIndexer#keep")
    end

    it "follows rule (v) from a method another file calls, and through a default argument" do
      parsed = {
        DeclarationProducerScan::RULE_V_FILE => Prism.parse(<<~RUBY).value,
          module Rigor
            module ScopeIndexer
              def summary_for(root, acc) = walk(root, acc)
              def walk(root, acc, _done = record(acc, root)) = root
              def record(table, root) = table << root
            end
          end
        RUBY
        "lib/rigor/caller.rb" => Prism.parse("Rigor::ScopeIndexer.summary_for(root, {})").value
      }
      # The fixture's module is `Rigor::ScopeIndexer`; the committed row names `Rigor::Inference::ScopeIndexer`.
      table = { DeclarationProducerScan::RULE_V_FILE => { module: "Rigor::ScopeIndexer", roots: [] } }

      expect(DeclarationProducerScan.producers(parsed, table).keys.map { |key| key.split("#", 2).last })
        .to contain_exactly("Rigor::ScopeIndexer#summary_for", "Rigor::ScopeIndexer#walk", "Rigor::ScopeIndexer#record")
    end

    it "marks a subclass of a collector, from another file and transitively" do
      parsed = {
        "lib/rigor/a.rb" => Prism.parse("module Rigor; class A; include DeclarationWalk::Collector; end; end").value,
        "lib/rigor/b.rb" => Prism.parse("module Rigor; class B < A; end; class C < Rigor::B; end; " \
                                        "class D < Object; end; end").value
      }

      expect(DeclarationProducerScan.producers(parsed))
        .to eq("lib/rigor/a.rb#Rigor::A" => ["include DeclarationWalk::Collector"],
               "lib/rigor/b.rb#Rigor::B" => ["A (a DeclarationWalk::Collector subclass)"],
               "lib/rigor/b.rb#Rigor::C" => ["Rigor::B (a DeclarationWalk::Collector subclass)"])
    end

    describe "rule (v)'s table" do
      def parse(sources) = sources.transform_values { |source| Prism.parse(source).value }

      def rule_v_keys(sources, table) = DeclarationProducerScan.producers(parse(sources), table).keys

      def problems(sources, table) = DeclarationWriterScan.source_problems(parse(sources), table)

      it "starts each file from its own roots" do
        sources = { "lib/a.rb" => "module A; def enter(t) = t << 1; end",
                    "lib/b.rb" => "module B; def enter(t) = t << 2; end" }
        table = { "lib/a.rb" => { module: "A", roots: %i[enter] }, "lib/b.rb" => { module: "B", roots: [] } }

        expect(DeclarationProducerScan.producers(parse(sources), table))
          .to eq("lib/a.rb#A#enter" => ["writes a table (rule v)"])
      end

      it "takes as a root what another file calls on the file's module, and on no other" do
        sources = { "lib/a.rb" => "module Rigor; module A; def enter(t) = t << 1; end; end",
                    "lib/b.rb" => "module Rigor; module B; def enter(t) = t << 2; end; end",
                    "lib/c.rb" => "module Rigor; B.enter([]); end" }
        table = { "lib/a.rb" => { module: "Rigor::A", roots: [] }, "lib/b.rb" => { module: "Rigor::B", roots: [] } }

        expect(rule_v_keys(sources, table)).to eq(["lib/b.rb#Rigor::B#enter"])
      end

      # `CheckRules` ends in `Rules` and `Analysis::Rules` has its last segment, but neither spells a trailing part
      # of `Rigor::Walk::Rules`; `::Walk::Rules` is anchored at the top level, where the module is not.
      it "reads a receiver as the module by its full name or a trailing part of it, from a segment's start" do
        rules = "module Rigor; module Walk; module Rules; def bare(t) = t << 1; def partial(t) = t << 2; " \
                "def full(t) = t << 3; def anchored(t) = t << 4; def suffix(t) = t << 5; def segment(t) = t << 6; " \
                "def rooted(t) = t << 7; end; end; end"
        callers = "Rules.bare([]); Walk::Rules.partial([]); Rigor::Walk::Rules.full([]); " \
                  "::Rigor::Walk::Rules.anchored([]); CheckRules.suffix([]); Analysis::Rules.segment([]); " \
                  "::Walk::Rules.rooted([])"
        table = { "lib/rules.rb" => { module: "Rigor::Walk::Rules", roots: [] } }

        expect(rule_v_keys({ "lib/rules.rb" => rules, "lib/callers.rb" => callers }, table))
          .to contain_exactly("lib/rules.rb#Rigor::Walk::Rules#bare", "lib/rules.rb#Rigor::Walk::Rules#partial",
                              "lib/rules.rb#Rigor::Walk::Rules#full", "lib/rules.rb#Rigor::Walk::Rules#anchored")
      end

      it "follows a call a file makes on its own module by name, and not one on another module" do
        source = "module Rigor; module B; def enter(t) = B.record(t); def record(t) = t << 1; " \
                 "def far(t) = Other::B.lost(t); def lost(t) = t << 2; end; end"
        table = { "lib/b.rb" => { module: "Rigor::B", roots: %i[enter far] } }

        expect(rule_v_keys({ "lib/b.rb" => source }, table))
          .to contain_exactly("lib/b.rb#Rigor::B#enter", "lib/b.rb#Rigor::B#record")
      end

      it "reports a root that is not a method of the module in its file" do
        sources = { "lib/a.rb" => "module A; def enter(t) = t << 1; class Inner; def nested = 1; end; end" }

        expect(problems(sources, { "lib/a.rb" => { module: "A", roots: %i[enter] } })).to eq([])
        expect(problems(sources, { "lib/a.rb" => { module: "A", roots: %i[enter nested moved] } }))
          .to eq(["lib/a.rb: root nested is not a method of A here", "lib/a.rb: root moved is not a method of A here"])
      end

      it "reports a listed file that is not covered, and a file that defines no method of its module" do
        sources = { "lib/a.rb" => "module A; def enter(t) = t << 1; end" }

        expect(problems(sources, { "lib/gone.rb" => { module: "A", roots: [] } }))
          .to eq(["lib/gone.rb: listed for rule (v), but not a covered file"])
        expect(problems(sources, { "lib/a.rb" => { module: "Rigor::A", roots: %i[enter] } }))
          .to eq(["lib/a.rb: defines no method of Rigor::A"])
      end

      it "reports a file the rule starts nowhere in, which a call from the file itself does not enter" do
        sources = { "lib/b.rb" => "module B; def unused(t) = B.record(t); def record(t) = t << 1; end" }
        table = { "lib/b.rb" => { module: "B", roots: [] } }

        expect(rule_v_keys(sources, table)).to eq([])
        expect(problems(sources, table))
          .to eq(["lib/b.rb: rule (v) starts nowhere, no root of its row and no call on B from another covered " \
                  "file naming a method here"])
        expect(problems(sources.merge("lib/c.rb" => "B.record([])"), table)).to eq([])
      end
    end

    it "reports a new producer and a vanished one" do
      found = { "lib/a.rb#A#x" => ["Prism::ClassNode"] }

      expect(tripwire_problems(found, ["lib/b.rb#B#y"]))
        .to eq(["lib/a.rb#A#x: a producer (Prism::ClassNode), not in producers.yml",
                "lib/b.rb#B#y: in producers.yml but no longer a producer"])
    end

    it "regenerates a new entry as TODO, which the justification check rejects" do
      text = DeclarationFactSources.regenerate_producers_text("# head\n\n", ["lib/a.rb#A#x"])

      expect(text).to eq("# head\n\nlib/a.rb:\n  computes: TODO\n  producers:\n    A#x: TODO\n")
      expect(unjustified(YAML.safe_load(text))).to eq(["lib/a.rb computes", "lib/a.rb#A#x"])
    end
  end

  describe "regeneration (#1942)" do
    def regenerate(text, keys) = DeclarationFactSources.regenerate_producers_text(text, keys)

    def changed_lines(before, after)
      before_lines = before.lines
      after_lines = after.lines
      { removed: before_lines - after_lines, added: after_lines - before_lines }
    end

    it "is a byte-for-byte no-op on the current tree" do
      committed = File.read(snapshot)

      expect(regenerate(committed, found.keys)).to eq(committed)
    end

    it "touches only the affected entries when a producer appears and another vanishes" do
      committed = File.read(snapshot)
      keys = found.keys
      vanished = keys.find { |key| key.start_with?("lib/rigor/inference/scope_indexer.rb#") }
      added = ["lib/rigor/inference/scope_indexer.rb#Rigor::Inference::ScopeIndexer#aa_synthetic",
               "lib/rigor/inference/zz_synthetic.rb#Rigor::Zz#probe"]

      after = regenerate(committed, (keys - [vanished]) + added)
      diff = changed_lines(committed, after)

      expect(diff[:added]).to contain_exactly(
        "    Rigor::Inference::ScopeIndexer#aa_synthetic: TODO\n", "lib/rigor/inference/zz_synthetic.rb:\n",
        "  computes: TODO\n", "    Rigor::Zz#probe: TODO\n"
      )
      expect(after).to include("lib/rigor/inference/zz_synthetic.rb:\n  computes: TODO\n  producers:\n    Rigor::Zz#probe")
      expect(diff[:removed].size).to eq(1)
      expect(diff[:removed].first).to start_with("    #{vanished.split('#', 2).last}:")
      expect(unjustified(YAML.safe_load(after))).to include("lib/rigor/inference/zz_synthetic.rb#Rigor::Zz#probe")
    end

    it "keeps a reason's full text, its folded block and the entries' order" do
      text = <<~YAML
        # head

        lib/a.rb:
          computes: reads it (#1, #2)
          producers:
            A#zed: why (issue #1697); it derives nothing
            A#alpha: >-
              folded one
              folded two
      YAML

      expect(regenerate(text, %w[lib/a.rb#A#alpha lib/a.rb#A#zed])).to eq(text)
      expect(regenerate(text, %w[lib/a.rb#A#alpha lib/a.rb#A#beta lib/a.rb#A#zed]))
        .to eq(text.sub("    A#zed", "    A#beta: TODO\n    A#zed"))
    end

    it "keeps a multi-line computes block, whatever its continuation lines look like" do
      text = "lib/b.rb:\n  computes: >-\n    first line\n    indented4: yes\n  producers:\n    B#y: r\n"

      expect(regenerate(text, ["lib/b.rb#B#y"])).to eq(text)
    end

    it "drops a file left with no entries and inserts a new file in sort position" do
      text = "lib/a.rb:\n  computes: a\n  producers:\n    A#x: r\nlib/c.rb:\n  computes: c\n  producers:\n    C#z: r\n"
      b = "lib/b.rb:\n  computes: TODO\n  producers:\n    B#y: TODO\n"

      expect(regenerate(text, %w[lib/a.rb#A#x lib/b.rb#B#y lib/c.rb#C#z]))
        .to eq(text.sub("lib/c.rb:", "#{b}lib/c.rb:"))
      expect(regenerate(text, %w[lib/a.rb#A#x])).to eq(text.split("lib/c.rb:").first)
      expect(regenerate(text, %w[lib/a.rb#A#x lib/c.rb#C#z lib/d.rb#D#w]))
        .to eq("#{text}lib/d.rb:\n  computes: TODO\n  producers:\n    D#w: TODO\n")
    end

    it "round-trips a key the writer had to quote" do
      text = "lib/a.rb:\n  computes: a\n  producers:\n    \"*s\": why\n"

      expect(regenerate(text, ["lib/a.rb#*s"])).to eq(text)
      expect(regenerate("lib/a.rb:\n  computes: a\n  producers:\n", ["lib/a.rb#*s"])).to eq(text.sub("why", "TODO"))
    end

    it "adds the newline a file lacks before inserting" do
      text = "lib/a.rb:\n  computes: a\n  producers:\n    A#x: r"

      expect(regenerate(text, %w[lib/a.rb#A#x lib/a.rb#A#y])).to eq("#{text}\n    A#y: TODO\n")
    end
  end
end
