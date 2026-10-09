# frozen_string_literal: true

# Issue #1672 — gem source inference (`dependencies.source_inference:`) recognises `refine X do … end` bodies.
#
# A refine-body `def` in an opted-in gem is a refinement of X, visible after `using M`, and not an instance method
# of the refining module M. Before the fix the walker filed it as `M#shout` and the project's refinement table
# never learnt `String#shout`, so `using M; "hi".shout` reported `call.undefined-method`.
#
# Every expectation below is the answer CRuby gives for the same source: a silent line runs, a reported line
# raises `NoMethodError`.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/cache/store"
require "rigor/configuration"

RSpec.describe "Gem source inference over `refine` bodies (#1672)" do
  around do |example|
    Dir.mktmpdir("rigor-gem-refine-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:gem_dir) { File.join(Dir.pwd, "vendor", "shouty") }

  before do
    write("vendor/shouty/lib/shouty.rb", <<~RUBY)
      module Shouty
        refine String do
          def shout = upcase + "!"
        end

        def whisper = "psst"
      end
    RUBY
    spec = instance_double(Gem::Specification, version: Gem::Version.new("1.0.0"), full_gem_path: gem_dir)
    allow(Rigor::Analysis::DependencySourceInference::GemResolver)
      .to receive(:locate_gem_spec).and_call_original
    allow(Rigor::Analysis::DependencySourceInference::GemResolver)
      .to receive(:locate_gem_spec).with("shouty").and_return(spec)
  end

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration(workers: 0)
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "workers" => workers,
        "dependencies" => { "source_inference" => [{ "gem" => "shouty", "mode" => "when_missing" }] }
      )
    )
  end

  # `[file basename, line, method name]` for every `call.undefined-method`, sorted.
  def undefined_rows(cache_store: nil, workers: 0)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(workers: workers), cache_store: cache_store)
    guarded_run(runner, %w[lib]).diagnostics
                                .select { |d| d.qualified_rule == "call.undefined-method" }
                                .map { |d| [File.basename(d.path.to_s), d.line, d.method_name.to_s] }
                                .sort
  end

  it "resolves a gem refinement after `using`, and reports it before" do
    write("lib/app.rb", <<~RUBY)
      "early".shout
      using Shouty
      "hi".shout
      "hi".nope
    RUBY

    expect(undefined_rows).to eq([["app.rb", 1, "shout"], ["app.rb", 4, "nope"]])
  end

  it "still reports a refined call in a project that never `using`s the module" do
    write("lib/app.rb", <<~RUBY)
      "hi".shout
    RUBY

    expect(undefined_rows).to eq([["app.rb", 1, "shout"]])
  end

  # A value typed as a module declines `call.undefined-method` whatever its methods (#739), so the catalogue
  # entry itself is the observable: the dispatcher's gem-source tier reads `contribution_for`.
  it "does not file a refine-body def as the refining module's own method" do
    write("lib/app.rb", "using Shouty\n")
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    guarded_run(runner, %w[lib])
    index = runner.dependency_source_index

    expect(index.contribution_for(class_name: "Shouty", method_name: :whisper)).not_to be_nil
    expect(index.contribution_for(class_name: "Shouty", method_name: :shout)).to be_nil
    expect(index.refinements).to include("String" => { shout: ["Shouty"] })
  end

  it "seeds a file re-analysed on a warm run with the gem refinements" do
    write("lib/app.rb", <<~RUBY)
      using Shouty
      "hi".shout
      "hi".nope
    RUBY
    root = File.join(Dir.pwd, ".rigor-cache")
    cold = undefined_rows(cache_store: Rigor::Cache::Store.new(root: root))
    File.write("lib/app.rb", "#{File.read("lib/app.rb")}\"again\".shout\n")

    warm = undefined_rows(cache_store: Rigor::Cache::Store.new(root: root))

    expect(cold).to eq([["app.rb", 3, "nope"]])
    expect(warm).to eq(cold)
  end

  it "seeds pool workers with the gem refinements" do
    write("lib/app.rb", <<~RUBY)
      using Shouty
      "hi".shout
      "hi".nope
    RUBY
    write("lib/other.rb", "\"x\".shout\n")

    expect(undefined_rows(workers: 2)).to eq([["app.rb", 3, "nope"], ["other.rb", 1, "shout"]])
  end
end
