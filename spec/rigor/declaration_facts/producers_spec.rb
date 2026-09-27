# frozen_string_literal: true

require "spec_helper"
require "digest"
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
# no entry in `DeclarationWriterScan::ROOTS` reaches. Plugin specs and demo apps are not scanned. The list freezes the
# set and certifies nothing about how an entry computes its context.
RSpec.describe "Declaration producers" do
  let(:snapshot) { File.join(__dir__, "producers.yml") }
  let(:header) do
    <<~YAML
      # Declaration producers (#1507, ADR-119 WD6): every method, or class or module body, under lib/ and
      # plugins/*/lib/ whose code decides what a declaration is. producers_spec.rb computes the set with Prism and
      # compares it with this file. Each file says what it computes, and each entry why it computes a declaration
      # context itself instead of going through DeclarationWalk::Context or ModuleFunctionState. `grandfathered`
      # marks the entries present when the tripwire landed; they converge as bugs are filed. A new entry must say
      # why; `RIGOR_REGENERATE_GATES=1` adds new entries as TODO, which the spec fails on.

    YAML
  end

  # The closed grandfathered list. Lower it when an entry goes; never raise it for a new producer.
  let(:grandfathered_pin) do
    { count: 371, digest: "07a9729d32eade6934d5e87ab4752b95e4d6201eed68ed18896eb52f09b5927c" }
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

  # `recorded` brought in line with `found`: new files and entries as TODO, vanished ones dropped.
  define_method(:regenerated) do |found, recorded|
    found.keys.group_by { |key| key.split("#", 2).first }.sort.to_h do |path, keys|
      entries = keys.map { |key| key.split("#", 2).last }.sort.to_h do |scope|
        [scope, recorded.dig(path, "producers", scope) || "TODO"]
      end
      [path, { "computes" => recorded.dig(path, "computes") || "TODO", "producers" => entries }]
    end
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
      DeclarationFactSources.write_yaml(snapshot, header, regenerated(current, YAML.load_file(snapshot)))
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
      regenerated = regenerated({ "lib/a.rb#A#x" => ["Prism::ClassNode"] }, {})

      expect(regenerated).to eq("lib/a.rb" => { "computes" => "TODO", "producers" => { "A#x" => "TODO" } })
      expect(unjustified(regenerated)).to eq(["lib/a.rb computes", "lib/a.rb#A#x"])
    end
  end
end
