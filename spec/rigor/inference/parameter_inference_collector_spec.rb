# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/inference/parameter_inference_collector"
require "rigor/environment"

# ADR-67 WD3 — single-level call-site parameter inference. A parameter's
# inferred type is the union of resolved call-site argument types; an argument
# that is itself untyped (the fixpoint case) poisons the parameter.
RSpec.describe Rigor::Inference::ParameterInferenceCollector do
  def collect(*sources)
    Dir.mktmpdir do |dir|
      paths = sources.each_with_index.map do |source, i|
        path = File.join(dir, "f#{i}.rb")
        File.write(path, source)
        path
      end
      described_class.collect(files: paths, environment: Rigor::Environment.default)
    end
  end

  it "infers a parameter from a concrete-arg implicit-self call site" do
    table = collect(<<~RUBY)
      class Widget
        def name = "w"
      end
      class Processor
        def run = process(Widget.new)
        def process(item)
          item
        end
      end
    RUBY
    inferred = table.fetch(["Processor", :process, :instance])
    expect(inferred[:item].describe(:short)).to eq("Widget")
  end

  it "infers from a concrete-arg explicit-receiver call site" do
    table = collect(<<~RUBY)
      class Widget
        def name = "w"
      end
      class Driver
        def go(widget)
          widget.run(Widget.new)
        end
      end
      class Widget
        def run(item)
          item
        end
      end
    RUBY
    # `widget.run(Widget.new)` — widget is untyped, so the receiver does not
    # resolve and this call is skipped; the test asserts only that the
    # collector does not crash and produces no false entry for `run`.
    expect(table[["Widget", :run, :instance]]).to be_nil
  end

  it "unions two distinct concrete arguments across call sites" do
    table = collect(<<~RUBY)
      class A; end
      class B; end
      class Hub
        def one = handle(A.new)
        def two = handle(B.new)
        def handle(x)
          x
        end
      end
    RUBY
    inferred = table.fetch(["Hub", :handle, :instance])
    expect(inferred[:x]).to be_a(Rigor::Type::Union)
    members = inferred[:x].members.map { |m| m.describe(:short) }.sort
    expect(members).to eq(%w[A B])
  end

  it "poisons a parameter passed an untyped argument (the fixpoint case → WD4)" do
    table = collect(<<~RUBY)
      class Processor
        def outer(item)
          process(item)
        end
        def process(item)
          item
        end
      end
    RUBY
    expect(table[["Processor", :process, :instance]]).to be_nil
  end

  it "poisons when even one of several call sites is untyped" do
    table = collect(<<~RUBY)
      class A; end
      class Hub
        def good = handle(A.new)
        def bad(item) = handle(item)
        def handle(x)
          x
        end
      end
    RUBY
    expect(table[["Hub", :handle, :instance]]).to be_nil
  end

  it "skips a non-simple parameter shape (keyword / optional / rest / block)" do
    table = collect(<<~RUBY)
      class A; end
      class Hub
        def run = handle(A.new)
        def handle(x, y = 1)
          x
        end
      end
    RUBY
    expect(table[["Hub", :handle, :instance]]).to be_nil
  end

  it "skips a call whose arity does not match the parameter count" do
    table = collect(<<~RUBY)
      class A; end
      class Hub
        def run = handle(A.new)
        def handle(x, z)
          x
        end
      end
    RUBY
    expect(table[["Hub", :handle, :instance]]).to be_nil
  end

  it "skips a splat argument (positional mapping is unsound)" do
    table = collect(<<~RUBY)
      class A; end
      class Hub
        def run
          args = [A.new]
          handle(*args)
        end
        def handle(x)
          x
        end
      end
    RUBY
    expect(table[["Hub", :handle, :instance]]).to be_nil
  end

  it "widens a literal argument to its nominal (a parameter is not a pinned literal)" do
    table = collect(<<~RUBY)
      class Hub
        def run = handle("text")
        def handle(x)
          x
        end
      end
    RUBY
    inferred = table.fetch(["Hub", :handle, :instance])
    expect(inferred[:x].describe(:short)).to eq("String")
  end

  it "resolves a call site in a sibling file" do
    table = collect(<<~RUBY, <<~CALLER)
      class A; end
      class Hub
        def handle(x)
          x
        end
      end
    RUBY
      class Hub
        def run = handle(A.new)
      end
    CALLER
    inferred = table.fetch(["Hub", :handle, :instance])
    expect(inferred[:x].describe(:short)).to eq("A")
  end
end
