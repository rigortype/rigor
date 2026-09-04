# frozen_string_literal: true

# Issue #746 — a class that includes a module the RBS environment does not know has a method surface Rigor
# cannot enumerate, so `call.undefined-method` must not fire on it.
#
# `SudoMode::Form` includes `ActiveModel::Validations`, which no RBS in redmine's environment declares, and
# `valid?` comes from it. The rule enumerated the part of the class it could see and reported the rest. That
# is the same unsoundness `unbounded_receiver_surface?` already refuses for an ADR-26 open receiver and for
# Rigor's own synthesized stubs: a class whose ancestors are not fully known is not a class whose methods
# can be enumerated.
#
# Same precondition as #736 / #739 / #744: while the class has no RBS the rule cannot speak about it at all,
# so the shape appears the moment a `sig/` — hand-written or generated — declares it.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a class including an unknown module (#746)" do
  def write_project(source)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "form.rbs"), <<~RBS)
      module Known
      end
      class Form
      end
      class Plain
      end
    RBS
    File.write(File.join("lib", "form.rb"), source)
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0
      )
    )
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    )
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-unknown-mixin-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not fire on a class whose include the environment does not know" do
    write_project(<<~RUBY)
      class Form
        include SomeGem::Validations

        def check = self.valid?
      end
    RUBY
    expect(undefined_messages).to be_empty
  end

  it "still fires when every include is known" do
    # Mandatory must-still-fire: the stand-down is about ancestors Rigor cannot see, not about classes that
    # happen to include something. `Known` is declared in the same `sig/`, so the surface IS enumerable.
    write_project(<<~RUBY)
      module Known
        def helper = 1
      end

      class Plain
        include Known

        def go = self.no_such_method
      end
    RUBY
    expect(undefined_messages).to eq(["undefined method `no_such_method' for Plain"])
  end

  it "still fires for a class with no includes at all" do
    write_project(<<~RUBY)
      class Plain
        def go = self.no_such_method
      end
    RUBY
    expect(undefined_messages).to eq(["undefined method `no_such_method' for Plain"])
  end
end
