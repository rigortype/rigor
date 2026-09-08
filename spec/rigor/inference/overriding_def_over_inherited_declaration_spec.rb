# frozen_string_literal: true

# Issue #744 half 2, adjudicated in ADR-110 and implemented as #856.
#
# RBS resolves a subclass's undeclared method through its ancestors, so `RbsDispatch` answered a call on a
# subclass with a signature written about the base. redmine's `Redmine::FieldFormat::Base#target_class`
# honestly declares `-> nil` and `RecordList` overrides it with a real lookup; every call on a `RecordList`
# receiver typed as `nil` and fired `undefined method ... for nil` at four sites on the subclass's own
# working code, plus a `def.return-type-mismatch` calling the correct override wrong.
#
# The gate is `ExpressionTyper#try_overriding_def_dispatch`, and its three conditions are all load-bearing:
# the receiver's class has its own source `def`, no declaration of its own, and the ancestor whose
# declaration would answer is PROJECT-declared. The third is the blast radius — without it a project class
# with `def each` would disqualify `Enumerable#each`, which is the blanket fix ADR-43 rejected.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "an overriding def beats an inherited declaration (#744 half 2)" do
  # The shape `sig-gen --write` produced on redmine: the base's return typed precisely, the override
  # unsigned because the generator could not type it.
  def write_project(rbs:, base_body:, child:)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "fmt.rbs"), rbs)
    File.write(File.join("lib", "base.rb"), <<~RUBY)
      module Fmt
        class Base
          def target_class = #{base_body}
        end
      end
    RUBY
    File.write(File.join("lib", "child.rb"), child)
  end

  def run_check
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0
      )
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
  end

  def undefined_messages(result)
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-overriding-def-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # The base declared, the override unsigned — the exact shape that produced redmine's four sites.
  def base_only_rbs
    <<~RBS
      module Fmt
        class Base
          def target_class: () -> nil
        end
        class RecordList < Fmt::Base
        end
      end
    RBS
  end

  def overriding_child
    <<~RUBY
      module Fmt
        class RecordList < Base
          def target_class = "Issue"

          def probe
            Rigor.dump_type(self.target_class)
            self.target_class.upcase
          end
        end
      end
    RUBY
  end

  it "types the call from the override, not from the base's declaration" do
    write_project(rbs: base_only_rbs, base_body: "nil", child: overriding_child)
    result = run_check
    expect(undefined_messages(result)).to be_empty
    expect(dumps(result)).to eq(['dump_type: "Issue"'])
  end

  it "leaves the inherited declaration answering when the subclass does NOT override" do
    # The must-still-bind half. With no `def` of its own the inherited declaration IS about the method
    # that runs, so nothing is disqualified and the base's `nil` is still the answer.
    write_project(rbs: base_only_rbs, base_body: "nil", child: <<~RUBY)
      module Fmt
        class RecordList < Base
          def probe
            Rigor.dump_type(self.target_class)
          end
        end
      end
    RUBY
    expect(dumps(run_check)).to eq(["dump_type: nil"])
  end

  it "keeps a declaration the overriding class carries itself" do
    # Both sides authored: the override has a contract written about it, so the gate stands down and the
    # declaration binds exactly as before.
    write_project(rbs: <<~RBS, base_body: "nil", child: overriding_child)
      module Fmt
        class Base
          def target_class: () -> nil
        end
        class RecordList < Fmt::Base
          def target_class: () -> String
        end
      end
    RBS
    result = run_check
    expect(undefined_messages(result)).to be_empty
    expect(dumps(result)).to eq(["dump_type: String"])
  end

  it "does not disqualify a BUNDLED ancestor's declaration (the ADR-43 bound)" do
    # `Object#to_s` is bundled RBS, not a project sidecar. A project `def to_s` is a monkey-patch of a
    # class the project does not own — ADR-17's question, not this gate's — and disqualifying every
    # inherited core declaration is the blanket fix ADR-43 rejected.
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "thing.rbs"), <<~RBS)
      class Thing
      end
    RBS
    File.write(File.join("lib", "thing.rb"), <<~RUBY)
      class Thing
        def to_s = :not_a_string

        def probe
          Rigor.dump_type(self.to_s)
        end
      end
    RUBY
    expect(dumps(run_check)).to eq(["dump_type: String"])
  end
end
