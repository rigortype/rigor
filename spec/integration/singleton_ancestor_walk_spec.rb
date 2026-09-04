# frozen_string_literal: true

# Issue #731 — a class method defined on a project base class answers on its subclasses.
#
# The singleton-side lookup resolved the receiver's OWN name only (`Scope#singleton_def_for`), an explicit
# deferral from the ADR-57 module-singleton follow-up, while the instance side had walked the ancestor chain
# since ADR-24 slice 2. On one fixture `Plain.new.inst` resolved and `Plain.build` read `Dynamic[top]`,
# which is every inherited factory / registry / `class << self` helper in a project hierarchy.
#
# Superclasses only, and that is the whole shape of class-method inheritance: an `include`d module's
# `def self.x` is not callable on the includer, and `extend M` is folded into the extender's own singleton
# entries by `ScopeIndexer` before the table is frozen.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a class method inherited from a project superclass (#731)" do
  def run_source(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "demo.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-singleton-ancestor-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "resolves through the superclass chain, plainly and through a rooted header" do
    result = run_source(<<~RUBY)
      class Base
        def self.build = :built
        def inst = :inst
      end

      class Plain < Base
      end

      module Admin
        class Nested < ::Base
        end
      end

      module Runner
        def self.go
          Rigor.dump_type(Base.build)
          Rigor.dump_type(Plain.build)
          Rigor.dump_type(Admin::Nested.build)
          Rigor.dump_type(Plain.new.inst)
        end
      end
    RUBY
    expect(dumps(result)).to eq(
      ["dump_type: :built", "dump_type: :built", "dump_type: :built", "dump_type: :inst"]
    )
  end

  it "degrades when a subclass redefines the inherited class method" do
    # The ADR-57 N5 overridable gate, now reached through an INHERITED owner: `Base.build`'s literal is the
    # default rather than the value every receiver sees, so adopting it would be unsound. This is why the
    # owner — not the receiver class — is what the gate keys on; passing the receiver would have adopted
    # `:built` for `Plain` here.
    result = run_source(<<~RUBY)
      class Base
        def self.build = :built
      end

      class Plain < Base
      end

      class Overrider < Base
        def self.build = :overridden
      end

      module Runner
        def self.go
          Rigor.dump_type(Plain.build)
          Rigor.dump_type(Overrider.build)
        end
      end
    RUBY
    expect(dumps(result)).to eq(["dump_type: Dynamic[top]", "dump_type: :overridden"])
  end

  it "does not resolve a module's own class method through an include" do
    # Must-still-degrade: `include` contributes instance methods. `Factory.build` is not callable on the
    # includer at runtime, so resolving it here would be a false answer, not a precision win.
    result = run_source(<<~RUBY)
      module Factory
        def self.build = :built
      end

      class Widget
        include Factory
      end

      module Runner
        def self.go
          Rigor.dump_type(Widget.build)
        end
      end
    RUBY
    expect(dumps(result)).to eq(["dump_type: Dynamic[top]"])
  end

  it "still resolves a class method contributed by extend" do
    # The other half of that pair: `extend` DOES put the module's instance methods on the singleton, and
    # `ScopeIndexer` folds it into the extender's own entries — so it resolves without any walk.
    result = run_source(<<~RUBY)
      module Naming
        def label = :labelled
      end

      class Widget
        extend Naming
      end

      module Runner
        def self.go
          Rigor.dump_type(Widget.label)
        end
      end
    RUBY
    expect(dumps(result)).to eq(["dump_type: :labelled"])
  end

  it "leaves a class method no ancestor defines opaque" do
    result = run_source(<<~RUBY)
      class Base
        def self.build = :built
      end

      class Plain < Base
      end

      module Runner
        def self.go
          Rigor.dump_type(Plain.no_such_class_method)
        end
      end
    RUBY
    expect(dumps(result)).to eq(["dump_type: Dynamic[top]"])
  end
end
