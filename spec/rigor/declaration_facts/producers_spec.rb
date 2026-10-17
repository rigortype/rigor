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
# writes outside `scope_indexer.rb`, through a local alias of a parameter, through `...` forwarding, or from a method
# reached only through `send`, a block handed to another file, or an entry point neither in
# `DeclarationWriterScan::ROOTS` nor called as `ScopeIndexer.x` from another covered file. Plugin specs and demo apps
# are not scanned. The list freezes the set and certifies nothing about how an entry computes its context.
RSpec.describe "Declaration producers" do
  let(:snapshot) { File.join(__dir__, "producers.yml") }
  # The closed grandfathered list. Lower it when an entry goes; never raise it for a new producer.
  let(:grandfathered_pin) do
    { count: 367, digest: "1db594c0b20dd580444ce351a513430c3bdf9510444d8f368095ed6fef6aa545" }
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

  it "justifies every file and entry" do
    missing = unjustified(YAML.load_file(snapshot))

    expect(missing).to eq([]), "Replace TODO in producers.yml: say what each file computes, and why each entry " \
                               "computes a declaration context itself.\n#{missing.join("\n")}"
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

      expect(DeclarationProducerScan.producers(parsed).keys.map { |key| key.split("#", 2).last })
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
