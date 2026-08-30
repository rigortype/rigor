# frozen_string_literal: true

require "tmpdir"

require "rigor/effects/definition_lines"

# #435 — the line half of a drift row's position. The contract is narrow on purpose: given a key and the
# file it was already traced to, answer the `def`'s line or nothing at all. Every "nothing at all" here is
# a row that keeps its file, never a raise on a run that had a report to print.
RSpec.describe Rigor::Effects::DefinitionLines do
  subject(:lines) { described_class.new }

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(name, source)
    File.write(name, source)
    name
  end

  it "answers an instance method inside a nested module" do
    path = write("nested.rb", <<~RUBY)
      module Tracer
        class Loud
          def emit
          end
        end
      end
    RUBY

    expect(lines.for(key: "Tracer::Loud#emit", path: path)).to eq(3)
  end

  # Both spellings of a singleton method, because the key's separator is what distinguishes them and a
  # `#`/`.` mix-up would silently answer the wrong line rather than none.
  it "distinguishes the singleton lane from the instance one" do
    path = write("singleton.rb", <<~RUBY)
      class Client
        def self.get
        end

        class << self
          def post
          end
        end

        def get
        end
      end
    RUBY

    expect(lines.for(key: "Client.get", path: path)).to eq(2)
    expect(lines.for(key: "Client.post", path: path)).to eq(6)
    expect(lines.for(key: "Client#get", path: path)).to eq(10)
  end

  it "reads a compact class path and a bare toplevel def" do
    path = write("compact.rb", <<~RUBY)
      def bare
      end

      class Tracer::Loud
        def emit
        end
      end
    RUBY

    expect(lines.for(key: "<toplevel>#bare", path: path)).to eq(1)
    expect(lines.for(key: "Tracer::Loud#emit", path: path)).to eq(5)
  end

  # A reopening within one file has two lines for one key, and only one of them is where a reader starts.
  it "answers the first def when a file defines the same method twice" do
    path = write("reopened.rb", <<~RUBY)
      class Loud
        def emit
        end
      end

      class Loud
        def emit
        end
      end
    RUBY

    expect(lines.for(key: "Loud#emit", path: path)).to eq(2)
  end

  describe "what it deliberately cannot answer" do
    it "returns nil for a method with no def at all" do
      path = write("accessor.rb", <<~RUBY)
        class Loud
          attr_reader :emit
        end
      RUBY

      expect(lines.for(key: "Loud#emit", path: path)).to be_nil
    end

    # Constant resolution is what an engine-free path does not have: `class Loud` inside `module Tracer`
    # is spelled `Tracer::Loud` by the scanner and by this, but a key reached through an alias or a
    # dynamically named class is one it cannot see. The row keeps its file.
    it "returns nil for a key this file does not spell" do
      path = write("other.rb", "class Loud\n  def emit\n  end\nend\n")

      expect(lines.for(key: "Tracer::Loud#emit", path: path)).to be_nil
    end

    it "returns nil for an unreadable file and for one that does not parse" do
      broken = write("broken.rb", "class Loud\n  def emit\n")

      expect(lines.for(key: "Loud#emit", path: broken)).to be_nil
      expect(lines.for(key: "Loud#emit", path: "no-such-file.rb")).to be_nil
    end
  end

  # The cost model the whole class exists for: proportional to the drift's files, and each of them once.
  it "parses each file once however many keys ask about it" do
    path = write("once.rb", "class Loud\n  def emit\n  end\n\n  def hush\n  end\nend\n")
    allow(Prism).to receive(:parse_file).and_call_original

    3.times do
      lines.for(key: "Loud#emit", path: path)
      lines.for(key: "Loud#hush", path: path)
      lines.for(key: "Loud#absent", path: path)
    end

    expect(Prism).to have_received(:parse_file).once
  end
end
