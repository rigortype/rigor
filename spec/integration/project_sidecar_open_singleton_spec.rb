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

    it "still reports `instance` when the project defines a top-level Singleton the class includes as `::Singleton`" do
      write("lib/a.rb", "module Singleton\nend\nclass X\n  include ::Singleton\n  def x = 1\nend\nX.instance\n")
      write("sig/a.rbs", "module Singleton\nend\nclass X\n  def x: () -> Integer\nend\n")

      expect(undefined_messages(run_check)).to eq(["undefined method `instance' for singleton(X)"])
    end

    # The tables drop a mixin argument's leading `::`, so `include ::Singleton` and `include Singleton` inside
    # `module N` read alike. Both are taken as the stdlib mixin: the rooted spelling types, and neither reports.
    it "types `instance` as the class when it includes ::Singleton beside a nested project Singleton" do
      write("lib/a.rb", <<~SOURCE)
        require "singleton"
        module N
          class Singleton
          end
          class X
            include ::Singleton
            def x = 1
          end
          class Y
            include Singleton
            def y = 1
          end
        end
        Rigor.dump_type(N::X.instance)
        N::Y.instance
      SOURCE
      write("sig/a.rbs", "module N\n  class Singleton\n  end\n  class X\n    def x: () -> Integer\n  end\n  " \
                         "class Y\n    def y: () -> Integer\n  end\nend\n")
      result = run_check

      expect(undefined_messages(result)).to eq([])
      expect(dumps(result)).to eq(["dump_type: N::X"])
    end

    it "still reports `instance` when a nested project Singleton is prepended" do
      write("lib/a.rb", "require \"singleton\"\nmodule N\n  module Singleton\n  end\n  class P\n    " \
                        "prepend Singleton\n    def x = 1\n  end\nend\nN::P.instance\n")
      write("sig/a.rbs", "module N\n  module Singleton\n  end\n  class P\n    def x: () -> Integer\n  end\nend\n")

      expect(undefined_messages(run_check)).to eq(["undefined method `instance' for singleton(N::P)"])
    end

    # `Singleton.included` raises TypeError for a module, so a class that includes such a module has no `instance`.
    it "still reports `instance` when only a module the class includes includes Singleton" do
      write("lib/a.rb", "require \"singleton\"\nmodule M\n  include Singleton\nend\nclass C\n  include M\n  " \
                        "def x = 1\nend\nC.instance\n")
      write("sig/a.rbs", "module M\nend\nclass C\n  include M\n  def x: () -> Integer\nend\n")

      expect(undefined_messages(run_check)).to eq(["undefined method `instance' for singleton(C)"])
    end

    # `prepend Singleton` runs `prepend_features`, not the `included` hook, so Ruby defines no `instance`.
    it "still reports `instance` on a class that prepends Singleton" do
      write("lib/a.rb", "require \"singleton\"\nclass A\n  prepend Singleton\n  def x = 1\nend\nA.instance\n")
      write("sig/a.rbs", "class A\n  def x: () -> Integer\nend\n")

      expect(undefined_messages(run_check)).to eq(["undefined method `instance' for singleton(A)"])
    end

    it "still reports `instance` called with an argument" do
      write_tag_manager
      write("lib/caller.rb", "TagManager.instance(1)\n")

      expect(undefined_messages(run_check)).to eq(["undefined method `instance' for singleton(TagManager)"])
    end

    it "does not report `instance` on a subclass of a class that includes Singleton, and types it as the subclass" do
      write("lib/a.rb", <<~RUBY)
        require "singleton"
        class C
          include Singleton
          def x = 1
        end
        class D < C
          def y = 2
        end
        Rigor.dump_type(D.instance)
        D.typo
      RUBY
      write("sig/a.rbs", "class C\n  def x: () -> Integer\nend\nclass D < C\n  def y: () -> Integer\nend\n")
      result = run_check

      expect(undefined_messages(result)).to eq(["undefined method `typo' for singleton(D)"])
      expect(dumps(result)).to eq(["dump_type: D"])
    end
  end

  describe "a member-less project declaration" do
    def messages_for(source, sidecar, files = {})
      write("lib/a.rb", source)
      write("sig/a.rbs", sidecar)
      files.each { |path, body| write(path, body) }
      undefined_messages(run_check)
    end

    it "does not report a class method on a namespace that extends a module" do
      messages = messages_for(
        "module NS\n  extend Helpers\n  class Foo\n    def y = NS.helper\n  end\nend\n",
        "module NS\n  class Foo\n    def y: () -> untyped\n  end\nend\n",
        # Outside `paths:`, so neither the analyzer nor sig-gen sees it.
        "ext/helpers.rb" => "module Helpers\n  def helper = 1\nend\n"
      )

      expect(messages).to eq([])
    end

    it "does not report a class method on a class that defines an inherited hook" do
      messages = messages_for(
        "class Base\n  def self.inherited(sub) = super\nend\nBase.registered\n", "class Base\nend\n"
      )

      expect(messages).to eq([])
    end

    # A plain `include` adds instance methods only, so the class's singleton side stays closed.
    it "still reports a class method on a class that includes a project module" do
      messages = messages_for(
        "module Conc\n  def c = 1\nend\nclass Svc\n  include Conc\nend\nSvc.helper\n", "class Svc\nend\n"
      )

      expect(messages).to eq(["undefined method `helper' for singleton(Svc)"])
    end

    # A project module the class extends is a mixin too, though the source shows every method it adds.
    it "does not report a class method on a class that extends a project module" do
      messages = messages_for("module H\n  def h = 1\nend\nclass W\n  extend H\nend\nW.helper\n", "class W\nend\n")

      expect(messages).to eq([])
    end

    it "still reports a class method on a class that includes a library module" do
      expect(messages_for("class Svc\n  include Comparable\nend\nSvc.helper\n", "class Svc\nend\n"))
        .to eq(["undefined method `helper' for singleton(Svc)"])
    end

    # Guard: a superclass chain past `ResolutionChain::LIMIT` is cut, so the class is not provably closed. The
    # rule's own ancestry budget declines the same call today, so removing the cut check alone does not fail this.
    it "does not report a class method on a class whose superclass chain is cut" do
      chain = (1..101).map { |i| "class C#{i} < C#{i - 1}\nend\n" }.join
      source = "class C0\nend\n#{chain}C101.fooo\n"

      expect(messages_for(source, "class C101\nend\n")).to eq([])
    end

    it "does not report a class method on a namespace with no body inside paths:" do
      messages = messages_for(
        "class Ext::Foo\n  def y = Ext.helper\nend\n",
        "module Ext\n  class Foo\n    def y: () -> untyped\n  end\nend\n"
      )

      expect(messages).to eq([])
    end

    it "does not report a class method on a class whose superclass chain reaches a library class" do
      messages = messages_for(
        "class ApplicationRecord < ActiveRecord::Base\nend\nclass Poll < ApplicationRecord\nend\nPoll.joins(:votes)\n",
        "class ApplicationRecord\nend\nclass Poll < ApplicationRecord\nend\n"
      )

      expect(messages).to eq([])
    end

    # The accepted cost of the superclass arm: a core superclass is a library class too, so a typo on a
    # member-less error class is not reported.
    it "does not report a class method on a class that subclasses a core class" do
      expect(messages_for("class MyErr < StandardError\nend\nMyErr.typo\n", "class MyErr < StandardError\nend\n"))
        .to eq([])
    end

    # The source writes no superclass here, so the declaration's own is read.
    it "does not report a class method on a class whose declaration names a core superclass" do
      expect(messages_for("class MyErr\nend\nMyErr.typo\n", "class MyErr < StandardError\nend\n")).to eq([])
    end

    it "still reports a typo when the declaration names a closed project class as the superclass" do
      messages = messages_for(
        "class Parent\nend\nclass Kid\nend\nKid.fooo\n", "class Parent\nend\nclass Kid < Parent\nend\n"
      )

      expect(messages).to eq(["undefined method `fooo' for singleton(Kid)"])
    end

    it "does not report a class method on a class whose superclass is an expression" do
      expect(messages_for("class K < Struct.new(:a)\nend\nK.fooo\n", "class K\nend\n")).to eq([])
    end

    it "still reports a typo on a closed class whose whole definition is inside paths:" do
      messages = messages_for("class Plain\nend\nPlain.fooo\n", "class Plain\nend\n")

      expect(messages).to eq(["undefined method `fooo' for singleton(Plain)"])
    end

    it "still reports a typo on a closed class that names Object as its superclass" do
      messages = messages_for("class Obj < Object\nend\nObj.fooo\n", "class Obj < Object\nend\n")

      expect(messages).to eq(["undefined method `fooo' for singleton(Obj)"])
    end

    it "still reports a typo on a closed class nested in a member-less namespace" do
      messages = messages_for(
        "module Admin\n  module Metrics\n  end\nend\n" \
        "class Admin::Metrics::Dimension\n  def self.retrieve(keys) = keys\nend\n" \
        "class Admin::Metrics::Dimension::Lang\nend\nAdmin::Metrics::Dimension.retreive([1])\n",
        "module Admin\n  module Metrics\n    class Dimension\n      class Lang\n      end\n    end\n  end\nend\n"
      )

      expect(messages).to eq(["undefined method `retreive' for singleton(Admin::Metrics::Dimension)"])
    end

    # Known limit: a file outside `paths:` is not read, so a namespace whose body is inside `paths:` and whose
    # class methods live only outside it reads as closed.
    it "still reports a class method defined only in a file outside paths:" do
      messages = messages_for(
        "module NS\n  class Foo\n    def y = NS.helper\n  end\nend\n",
        "module NS\n  class Foo\n    def y: () -> untyped\n  end\nend\n",
        "ext/ns.rb" => "module NS\n  def self.helper = 1\nend\n"
      )

      expect(messages).to eq(["undefined method `helper' for singleton(NS)"])
    end

    it "still reports once the declaration lists a member of its own" do
      messages = messages_for(
        "class Base\n  def self.inherited(sub) = super\nend\nBase.registered\n",
        "class Base\n  def self.known: () -> 1\nend\n"
      )

      expect(messages).to eq(["undefined method `registered' for singleton(Base)"])
    end

    # The instance side is left closed: the decline is for singleton calls only.
    it "still reports an instance-side call on a member-less class" do
      messages = messages_for("class W\n  extend Helpers\nend\nW.new.typo\n", "class W\nend\n")

      expect(messages).to eq(["undefined method `typo' for W"])
    end
  end

  # Guard: with no project `sig/` the class is source-only and open, as on the base. Nothing in the fix runs here.
  it "leaves a class with no project signature as it was" do
    write("lib/a.rb", "class Plain\n  def x = 1\nend\nPlain.typo\nPlain.instance\n")

    expect(undefined_messages(run_check)).to eq([])
  end
end
