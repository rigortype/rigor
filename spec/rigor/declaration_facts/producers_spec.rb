# frozen_string_literal: true

require "spec_helper"
require "yaml"

# #1507 — ADR-119 WD6's producer tripwire (proposed). `DeclarationProducerScan` parses every Ruby file under `lib/`
# and `plugins/*/lib/` with Prism and marks a method, or a class or module body, a producer when its code references
# `Prism::ClassNode`, `Prism::ModuleNode` or `Prism::SingletonClassNode` (a `when` arm, `is_a?`, `===`, a bare read),
# their node-type symbols (`:class_node`, …), a visibility or mixin keyword as a symbol (`:private`, `:include`, …),
# or a constant the same file assigns from any of those (`CLASS_BODY_NODES`). A class whose ancestry includes
# `DeclarationWalk::Collector` is a producer whatever it names. The set is compared with `producers.yml`, where each
# file also says what it computes, so a new producer, even a new method in a listed file, fails until it is recorded.
#
# What is not built: a producer that dispatches on `node.class.name` strings, on `Prism::Node#type` through a variable
# or on a keyword spelled as a String is not found; a collector in a file the suite does not load is found only by
# what it names; plugin specs and demo apps are not scanned. The list freezes the set and certifies nothing about how
# an entry computes its declaration context: sharing one helper is a review question, not a check here.
# A collector the tripwire's own ancestry test finds; it lives outside lib/, so the tree's check ignores it.
DeclarationFactSpecCollector = Class.new { include Rigor::Inference::DeclarationWalk::Collector }

RSpec.describe "Declaration producers" do
  let(:snapshot) { File.join(__dir__, "producers.yml") }
  let(:header) do
    <<~YAML
      # Declaration producers (#1507, ADR-119 WD6): every method, or class or module body, under lib/ and
      # plugins/*/lib/ whose code decides what a declaration is. producers_spec.rb computes the set with Prism and
      # compares it with this file. Each file says what it computes; `RIGOR_REGENERATE_GATES=1` rewrites the
      # producer lists and keeps the notes, and a new file's note is left empty for its author to write.

    YAML
  end

  define_method(:found) do |parsed = DeclarationFactSources.parsed_under|
    DeclarationProducerScan.producers(parsed).merge(DeclarationProducerScan.collectors(paths: parsed.keys))
  end

  define_method(:listed) do |recorded|
    recorded.flat_map { |path, entry| entry.fetch("producers").map { |scope| "#{path}##{scope}" } }
  end

  define_method(:tripwire_problems) do |found, listed|
    (found.keys - listed).sort.map { |key| "#{key}: a producer (#{found[key].join(', ')}) not in producers.yml" } +
      (listed - found.keys).sort.map { |key| "#{key}: in producers.yml but no longer a producer" }
  end

  define_method(:regenerated) do |found, recorded|
    found.keys.group_by { |key| key.split("#", 2).first }.sort.to_h do |path, keys|
      [path, { "computes" => recorded.dig(path, "computes").to_s,
               "producers" => keys.map { |key| key.split("#", 2).last }.sort }]
    end
  end

  it "lists exactly the producers the tree has" do
    recorded = YAML.load_file(snapshot)
    current = found
    if DeclarationFactSources.regenerate?
      DeclarationFactSources.write_yaml(snapshot, header, regenerated(current, recorded))
      recorded = YAML.load_file(snapshot)
    end

    problems = tripwire_problems(current, listed(recorded))
    expect(problems).to eq([]), "#{problems.join("\n")}\n#{DeclarationFactSources.regenerate_hint('producers.yml')}"
  end

  it "says what each listed file computes" do
    empty = YAML.load_file(snapshot).select { |_, entry| entry["computes"].to_s.strip.empty? }.keys

    expect(empty).to eq([]), "producers.yml: write a `computes:` note for #{empty.join(', ')}"
  end

  describe "the tripwire itself" do
    def producers_of(source, path = "lib/rigor/probe.rb")
      DeclarationProducerScan.producers(path => Prism.parse(source).value)
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
        .to eq("lib/rigor/inference/scope_indexer.rb#Rigor::ScopeIndexer#new_walk" => ["Prism::ClassNode"])
    end

    it "marks node-type symbols, keyword symbols and same-file constants, and skips keyword labels and comments" do
      source = <<~RUBY
        class Probe
          BODIES = [Prism::SingletonClassNode].freeze
          # Prism::ModuleNode in a comment
          def by_type(node) = node.type == :class_node
          def by_keyword(node) = node.name == :prepend
          def by_constant(node) = BODIES.include?(node.class)
          def by_label = call(include: true)
        end
      RUBY

      expect(producers_of(source).transform_keys { |key| key.split("#", 2).last })
        .to eq("Probe" => ["Prism::SingletonClassNode"], "Probe#by_type" => [":class_node"],
               "Probe#by_keyword" => [":prepend"], "Probe#by_constant" => ["BODIES (a constant of this file)"])
    end

    it "marks a class by its ancestry, whatever it names, and only in the scanned files" do
      key = "spec/rigor/declaration_facts/producers_spec.rb#DeclarationFactSpecCollector"

      expect(DeclarationProducerScan.collectors([DeclarationFactSpecCollector, String])).to eq(key => ["collector"])
      expect(DeclarationProducerScan.collectors([DeclarationFactSpecCollector], paths: ["lib/a.rb"])).to eq({})
    end

    it "reports a new producer and a vanished one" do
      found = { "lib/a.rb#A#x" => ["Prism::ClassNode"] }

      expect(tripwire_problems(found, ["lib/b.rb#B#y"]))
        .to eq(["lib/a.rb#A#x: a producer (Prism::ClassNode) not in producers.yml",
                "lib/b.rb#B#y: in producers.yml but no longer a producer"])
    end
  end
end
