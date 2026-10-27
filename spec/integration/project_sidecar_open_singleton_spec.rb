# frozen_string_literal: true

# Issue #2438 — a project sidecar `sig/` must not close a class's singleton surface that the source leaves open.
#
# A class Rigor knows only from source is open, so an unresolved call on it is silent. `rigor sig-gen --write`
# then declares the class, and `call.undefined-method` enumerated the declaration and reported two families of
# correct calls:
#
# - `TagManager.instance` on a class that `include`s the stdlib `Singleton`. The mixin's `included` hook
#   defines `instance`, so no declaration lists it, while `SingletonMixinDispatch` already typed the call.
# - `NS.helper` on the wrapper `module NS` sig-gen writes around a nested class, when `helper` is defined in a
#   file outside `paths:`. The declaration names the namespace without describing its methods.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a project sidecar sig and an open singleton surface (#2438)" do
  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
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
    Dir.mktmpdir("rigor-open-singleton-") { |dir| Dir.chdir(dir) { example.run } }
  end

  describe "a class that includes Singleton" do
    def write_tag_manager(singleton_source: nil)
      write("lib/singleton_shadow.rb", singleton_source) if singleton_source
      write("lib/tm.rb", <<~RUBY)
        require "singleton"
        class TagManager
          include Singleton
          def uri_for(x) = "u\#{x}"
        end
        Rigor.dump_type(TagManager.instance)
        TagManager.instance.uri_for(1)
      RUBY
      # What `rigor sig-gen --params=observed --write lib` writes: the instance method, no `instance`.
      write("sig/tm.rbs", "class TagManager\n  def uri_for: (untyped) -> String\nend\n")
    end

    it "does not report `instance`, which the typer resolves to the class's instance" do
      write_tag_manager
      result = run_check

      expect(undefined_messages(result)).to eq([])
      expect(dumps(result)).to eq(["dump_type: TagManager"])
    end

    it "still reports another class method the declaration does not list" do
      write_tag_manager
      write("lib/caller.rb", "TagManager.instanse\n")

      expect(undefined_messages(run_check)).to eq(["undefined method `instanse' for singleton(TagManager)"])
    end

    it "still reports `instance` on a class that does not include Singleton" do
      write("lib/p.rb", "class Plain\n  def x = 1\nend\nPlain.instance\n")
      write("sig/p.rbs", "class Plain\n  def x: () -> 1\nend\n")

      expect(undefined_messages(run_check)).to eq(["undefined method `instance' for singleton(Plain)"])
    end

    it "still reports `instance` when the project defines its own Singleton module" do
      write_tag_manager(singleton_source: "module Singleton\n  def hi = 1\nend\n")
      write("sig/singleton_shadow.rbs", "module Singleton\n  def hi: () -> 1\nend\n")

      expect(undefined_messages(run_check)).to eq(
        ["undefined method `instance' for singleton(TagManager)"] * 2
      )
    end
  end

  describe "a member-less namespace declaration" do
    def write_namespace(sidecar:)
      write("lib/a.rb", <<~RUBY)
        module NS
          class Foo
            def x = 1
            def y = NS.helper
          end
        end
      RUBY
      # Outside `paths:`, so neither the analyzer nor sig-gen sees it.
      write("ext/ns.rb", "module NS\n  def self.helper = 1\nend\n")
      write("sig/a.rbs", sidecar)
    end

    it "does not report a class method the declaration cannot enumerate" do
      write_namespace(sidecar: "module NS\n  class Foo\n    def x: () -> 1\n  end\nend\n")

      expect(undefined_messages(run_check)).to eq([])
    end

    it "still reports once the namespace's declaration lists a member of its own" do
      write_namespace(sidecar: "module NS\n  def self.known: () -> 1\n  class Foo\n    def x: () -> 1\n  end\nend\n")

      expect(undefined_messages(run_check)).to eq(["undefined method `helper' for singleton(NS)"])
    end

    # The instance side is left closed: the decline is for singleton calls only.
    it "still reports an instance-side call on a member-less class" do
      write("lib/w.rb", "module NS\n  class W\n  end\nend\nNS::W.new.typo\n")
      write("sig/w.rbs", "module NS\n  class W\n  end\nend\n")

      expect(undefined_messages(run_check)).to eq(["undefined method `typo' for NS::W"])
    end
  end

  # Guard: with no project `sig/` the class is source-only and open, as on the base. Nothing in the fix runs here.
  it "leaves a class with no project signature as it was" do
    write("lib/a.rb", "class Plain\n  def x = 1\nend\nPlain.typo\nPlain.instance\n")

    expect(undefined_messages(run_check)).to eq([])
  end
end
