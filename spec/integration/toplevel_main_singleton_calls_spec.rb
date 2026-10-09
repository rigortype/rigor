# frozen_string_literal: true

# Issue #1383 — a bare top-level call to one of `main`'s private singleton methods (`using`,
# `include`, `public`, `private`, `define_method`, `ruby2_keywords`) is correct Ruby and must not
# report `call.unresolved-toplevel`. An unknown bare name still reports.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "top-level calls to main's singleton methods (#1383)" do
  def diagnostics_for(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "main.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
      .diagnostics
  end

  def toplevel_messages(source)
    diagnostics_for(source).select { |d| d.qualified_rule == "call.unresolved-toplevel" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-toplevel-main-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "stays silent on main's singleton methods, at top level and inside a top-level block" do
    messages = toplevel_messages(<<~RUBY)
      module Helpers
        refine String do
          def shout = upcase
        end
      end

      using Helpers
      include Comparable
      public
      private
      define_method(:greet) { "hi" }
      private :greet
      public :greet
      ruby2_keywords

      [1].each do
        include Comparable
        private
        define_method(:wave) { "wave" }
      end
    RUBY

    expect(messages).to be_empty
  end

  it "still reports an unknown bare top-level call" do
    messages = toplevel_messages("frobnicate\n")

    expect(messages.size).to eq(1)
    expect(messages.first).to include("unresolved toplevel call to `frobnicate`")
  end

  it "leaves class-body using and include unchanged" do
    diagnostics = diagnostics_for(<<~RUBY)
      module Helpers
        refine String do
          def shout = upcase
        end
      end

      class Widget
        using Helpers
        include Comparable
      end
    RUBY

    expect(diagnostics.map(&:qualified_rule)).not_to include("call.unresolved-toplevel", "call.undefined-method")
  end
end
