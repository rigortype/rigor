# frozen_string_literal: true

# Issue #1703 — a `key?` guard with a non-literal key did not narrow the matching index read. A closed hash shape
# read by a computed key answers every value plus the miss `nil` (#1278), so typelizer 0.14.0's
# `COLUMN_TYPE_MAP.key?(property.column_type) && …` followed by `COLUMN_TYPE_MAP[property.column_type].dup` and a
# `[]=` on the copy reported `call.possible-nil-receiver` on correct code.
#
# The narrowing may only remove diagnostics. Each example below other than the first pins a way an earlier version of
# the fix added one, or kept narrowing where the guard no longer held; every source line marked `# fires` is a report
# the un-narrowed engine makes and this one must keep.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a key? guard with a non-literal key narrows the index read (#1703)" do
  def diagnostics(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "mapper.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    )
    result.diagnostics.map { |d| [d.line, d.qualified_rule] }
  end

  def marked_lines(source, rule)
    source.lines.each_index.select { |i| source.lines[i].include?("# fires") }.map { |i| [i + 1, rule] }
  end

  around do |example|
    Dir.mktmpdir("rigor-computed-key-guard-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:guarded) do
    <<~RUBY
      class Mapper
        MAP = { integer: { type: :integer }, string: { type: :string } }.freeze

        def by_local(prop)
          k = prop.column_type
          if MAP.key?(k)
            r = MAP[k].dup
            r[:a] = 1
          end
        end

        def by_chain(prop, mapping)
          if prop.column_type && MAP.has_key?(prop.column_type) && !overridden?(prop, mapping)
            result = MAP[prop.column_type].dup
            result[:type] = :string
            result
          end
        end

        def by_ivar
          if MAP.include?(@kind)
            r = MAP[@kind]
            r[:a] = 1
          end
        end

        def local_receiver(name)
          h = { a: { x: 1 }, b: { x: 2 } }
          k = name.to_sym
          if h.member?(k)
            r = h[k]
            r[:y] = 1
          end
        end

        def overridden?(_prop, mapping) = mapping.nil?
      end
    RUBY
  end

  let(:unguarded) do
    <<~RUBY
      class Mapper
        MAP = { integer: { type: :integer }, string: { type: :string } }.freeze
        NILS = { integer: { type: :integer }, none: nil }.freeze
        OPEN = { integer: { type: :integer }, string: { type: :string } }

        def key_rebound(prop)
          k = prop.column_type
          if MAP.key?(k)
            k = prop.other
            r = MAP[k]
            r[:a] = 1 # fires
          end
        end

        def key_root_called(prop)
          if MAP.key?(prop.column_type)
            prop.reload
            r = MAP[prop.column_type]
            r[:a] = 1 # fires
          end
        end

        def different_key(prop)
          if MAP.key?(prop.column_type)
            r = MAP[prop.sql_type]
            r[:a] = 1 # fires
          end
        end

        def intrinsic_nil(name)
          k = name.to_sym
          if NILS.key?(k)
            r = NILS[k]
            r[:a] = 1 # fires
          end
        end

        def false_branch(name)
          k = name.to_sym
          unless MAP.key?(k)
            r = MAP[k]
            r[:a] = 1 # fires
          end
        end

        def ivar_key_after_self_call
          if MAP.key?(@kind)
            refresh
            r = MAP[@kind]
            r[:a] = 1 # fires
          end
        end

        def consuming_key(queue)
          if MAP.key?(queue.shift)
            r = MAP[queue.shift]
            r[:a] = 1 # fires
          end
        end

        def receiver_passed(name)
          h = { a: { x: 1 }, b: { x: 2 } }
          k = name.to_sym
          if h.key?(k)
            purge(h, k)
            r = h[k]
            r[:y] = 1 # fires
          end
        end

        def receiver_aliased(name)
          h = { a: { x: 1 }, b: { x: 2 } }
          k = name.to_sym
          if h.key?(k)
            g = h
            g.delete(k)
            r = h[k]
            r[:y] = 1 # fires
          end
        end

        def constant_aliased(name)
          k = name.to_sym
          if OPEN.key?(k)
            g = OPEN
            g.delete(k)
            r = OPEN[k]
            r[:y] = 1 # fires
          end
        end

        def self_handed_on(name, other)
          @h = { a: { x: 1 }, b: { x: 2 } }
          k = name.to_sym
          if @h.key?(k)
            other.mutate_owner(self)
            r = @h[k]
            r[:y] = 1 # fires
          end
        end

        def purge(h, k) = h.delete(k)
        def refresh; end
      end
    RUBY
  end

  # The narrowed read and every value computed from it are optimistic: a check written against them stays live,
  # through a method `NilClass` answers (`to_i`, `to_s`, `inspect`, `to_a`) and past it, as it is without the guard.
  let(:defensive) do
    <<~RUBY
      class Mapper
        MAP = { integer: 1, string: 2 }.freeze
        STR = { a: "x", b: "y" }.freeze

        def rank(a, b)
          a = a.to_sym
          b = b.to_sym
          if MAP.key?(a) && MAP.key?(b)
            x = MAP[a]
            y = MAP[b]
            return 0 if x.nil? || y.nil?
            return 0 if MAP[a].nil? || MAP[b].nil?
            x < y ? 1 : 2
          end
        end

        def positive(k)
          if MAP.key?(k)
            return 1 if MAP[k].to_i > 0
            return 2 if MAP[k].to_i.positive?
            3
          end
        end

        def defaulted(k)
          if STR.key?(k)
            v = STR[k].to_s
            v = "default" if v == ""
            return v unless STR[k].to_s.empty?
            v
          end
        end

        def described(k)
          if MAP.key?(k)
            return 1 if MAP[k].inspect == "nil"
            MAP[k].to_a.empty? ? 2 : 3
          end
        end
      end
    RUBY
  end

  # A callee's return summary is computed without the guard: a narrowed type crossing the method boundary would
  # carry no optimistic mark, so the caller sees what it sees without the guard, the miss `nil` included.
  let(:caller_side) do
    <<~RUBY
      class Lookup
        TABLE = { a: "x", b: "y" }.freeze

        def find(name)
          return "none" unless TABLE.key?(name)
          TABLE[name]
        end
      end

      class Client
        def use(name)
          s = Lookup.new.find(name)
          Rigor.dump_type(s)
          return :missing if s.nil?
          s
        end
      end
    RUBY
  end

  it "drops the miss nil for a local, a reader chain and an ivar key, under every presence predicate" do
    expect(diagnostics(guarded)).to eq([])
  end

  it "keeps reporting where the guard no longer proves the read, and on the false branch" do
    expect(diagnostics(unguarded)).to eq(marked_lines(unguarded, "call.possible-nil-receiver"))
  end

  it "does not let a value computed from the narrowed read fold a defensive check into a certainty verdict" do
    expect(diagnostics(defensive)).to eq([])
  end

  it "does not publish the narrowed read in a method's return summary" do
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "mapper.rb"), caller_side)
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    rows = result.diagnostics.map { |d| [d.line, d.qualified_rule, d.message] }
    expect(rows).to eq([[13, "dump.type", "dump_type: \"none\" | \"x\" | \"y\" | nil"]])
  end
end
