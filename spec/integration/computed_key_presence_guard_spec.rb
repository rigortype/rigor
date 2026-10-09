# frozen_string_literal: true

# Issue #1703 — a `key?` guard with a non-literal key did not narrow the matching index read. A closed hash shape
# read by a computed key answers every value plus the miss `nil` (#1278), so typelizer 0.14.0's
# `COLUMN_TYPE_MAP.key?(property.column_type) && …` followed by `COLUMN_TYPE_MAP[property.column_type].dup` and a
# `[]=` on the copy reported `call.possible-nil-receiver` on correct code.

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

  let(:defensive) do
    <<~RUBY
      class Mapper
        MAP = { integer: 1, string: 2 }.freeze

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
      end
    RUBY
  end
  let(:unguarded) do
    <<~RUBY
      class Mapper
        MAP = { integer: { type: :integer }, string: { type: :string } }.freeze
        NILS = { integer: { type: :integer }, none: nil }.freeze

        def key_rebound(prop)
          k = prop.column_type
          if MAP.key?(k)
            k = prop.other
            r = MAP[k]
            r[:a] = 1
          end
        end

        def key_root_called(prop)
          if MAP.key?(prop.column_type)
            prop.reload
            r = MAP[prop.column_type]
            r[:a] = 1
          end
        end

        def different_key(prop)
          if MAP.key?(prop.column_type)
            r = MAP[prop.sql_type]
            r[:a] = 1
          end
        end

        def intrinsic_nil(name)
          k = name.to_sym
          if NILS.key?(k)
            r = NILS[k]
            r[:a] = 1
          end
        end

        def false_branch(name)
          k = name.to_sym
          unless MAP.key?(k)
            r = MAP[k]
            r[:a] = 1
          end
        end

        def ivar_key_after_self_call
          if MAP.key?(@kind)
            refresh
            r = MAP[@kind]
            r[:a] = 1
          end
        end

        def refresh; end
      end
    RUBY
  end

  it "drops the miss nil for a local, a reader chain and an ivar key, under every presence predicate" do
    expect(diagnostics(guarded)).to eq([])
  end

  it "keeps reporting where the guard no longer proves the read, and on the false branch" do
    expect(diagnostics(unguarded)).to eq(
      [10, 18, 25, 33, 41, 49].map { |line| [line, "call.possible-nil-receiver"] }
    )
  end

  it "does not let the narrowed read fold a defensive nil check into a certainty verdict" do
    # The narrowed read is marked optimistic, so the `||` polarity gate declines it (#313's shape); without the mark
    # both guards report `flow.always-truthy-condition`.
    expect(diagnostics(defensive)).to eq([])
  end
end
