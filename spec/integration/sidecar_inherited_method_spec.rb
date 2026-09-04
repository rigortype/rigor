# frozen_string_literal: true

# Issue #742 — #735's sidecar suppression asks about the receiver's OWN name, so a method the project
# defines on a base class one file away still fired.
#
# Two ancestry-aware probes exist and neither answers here: `ancestry_declares_method?` (#723) walks
# ancestors but reads `discovered_methods`, from which `ScopeIndexer#finalize_def_index` deliberately
# subtracts a plain cross-file `def`; #735's probe reads the def-SOURCE tables, which carry it, but only
# for the receiver's own class. The evidence and the walk were in different places.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "an inherited method under a sidecar sig (#742)" do
  # Declares both project classes and NONE of the inherited surface — the shape `sig-gen --write`
  # produces for a base class whose methods it could not type.
  def write_project
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "adapters.rbs"), <<~RBS)
      module Adapters
        class AbstractAdapter
        end
        class FilesystemAdapter < Adapters::AbstractAdapter
        end
        class Probe < Adapters::AbstractAdapter
        end
      end
    RBS
    File.write(File.join("lib", "base.rb"), <<~RUBY)
      module Adapters
        class AbstractAdapter
          def url = "file:///"
        end
      end
    RUBY
    File.write(File.join("lib", "core_ext.rb"), <<~RUBY)
      class String
        def blankish? = empty?
      end
    RUBY
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
    Dir.mktmpdir("rigor-sidecar-inherited-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not fire for a method the project base class defines" do
    write_project
    File.write(File.join("lib", "child.rb"), <<~RUBY)
      module Adapters
        class FilesystemAdapter < AbstractAdapter
          def target
            Rigor.dump_type(self.url)
            self.url
          end
        end
      end
    RUBY
    result = run_check
    expect(undefined_messages(result)).to be_empty
    # Must-still-resolve: the inherited method types from the base class's own body, so the suppression
    # is not the typer having gone opaque.
    expect(dumps(result)).to eq(['dump_type: "file:///"'])
  end

  it "still fires for a method no ancestor defines" do
    write_project
    File.write(File.join("lib", "child.rb"), <<~RUBY)
      module Adapters
        class Probe < AbstractAdapter
          def check = self.no_such_helper
        end
      end
    RUBY
    expect(undefined_messages(run_check)).to eq(
      ["undefined method `no_such_helper' for Adapters::Probe"]
    )
  end

  it "still fires for a cross-file def on a BUNDLED class" do
    # The widening is confined to classes the project declared in its own `sig/`. `String`'s signature is
    # authoritative, so the ADR-17 monkey-patch report — and its `pre_eval:` site — is untouched.
    write_project
    File.write(File.join("lib", "child.rb"), "def run = \"x\".blankish?\n")
    expect(undefined_messages(run_check)).to contain_exactly(
      a_string_starting_with("undefined method `blankish?' for \"x\"; the project defines")
    )
  end
end
