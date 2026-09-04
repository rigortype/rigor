# frozen_string_literal: true

# Issue #739 — a value typed as a mixin module has no enumerable method surface, so nothing can prove a
# method absent on it.
#
# Inside a module written to be included, `self` is not the module: it is an instance of whatever includes
# it, and that class contributes an arbitrary surface. RBS says the same thing about a parameter typed
# `Taggable` — "something whose class includes Taggable", not "something whose methods are Taggable's".
# redmine's `acts_as_*` mixins call the includer's surface constantly (`self.project`,
# `self.class.attachable_options`), and every one of those calls reported the moment a `sig/` declared the
# module.
#
# The union twin (`union_arm_blocks_undefined_fire?`) already declined such arms outright; the scalar rule
# only retried against `Object`. This closes that fork on the union's reading.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a mixin module receiver and call.undefined-method (#739)" do
  # Declares both modules and none of their methods — the partial sidecar that makes the rule able to
  # speak about these receivers at all.
  def write_project(source)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "mixin.rbs"), <<~RBS)
      module Attachable
        module InstanceMethods
        end
      end
      module Util
        def self?.helper: () -> Integer
      end
      class Widget
        def label: () -> String
      end
    RBS
    File.write(File.join("lib", "mixin.rb"), source)
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
    Dir.mktmpdir("rigor-module-mixin-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not fire for a call to the includer's surface" do
    # `self.project`, not a bare `project`: an implicit-self call has no receiver for this rule to speak
    # about and is `call.self-undefined-method`'s business (shipped `:off`). The explicit receiver is what
    # redmine's mixins write, and what fired.
    write_project(<<~RUBY)
      module Attachable
        module InstanceMethods
          def visible? = self.project
        end
      end
    RUBY
    expect(undefined_messages).to be_empty
  end

  it "does not fire for a call through self.class inside a mixin" do
    # The singleton twin: `self.class` is the includer's class at runtime, and the engine types it
    # `Singleton[<the module>]` — one hop along from the same wrong `self`.
    write_project(<<~RUBY)
      module Attachable
        module InstanceMethods
          def options = self.class.attachable_options
        end
      end
    RUBY
    expect(undefined_messages).to be_empty
  end

  it "still fires for a typo on a namespace module's own surface" do
    # Mandatory must-still-fire, and the reason the singleton case is keyed on the call-site syntax
    # rather than on `Singleton[M]`: a module with `module_function` / `def self.` has a real, enumerable
    # surface, and a type-only test would silence every `M.typo` in the project.
    write_project(<<~RUBY)
      module Util
        module_function

        def helper = 1
      end

      def run
        Util.helper
        Util.no_such_util
      end
    RUBY
    expect(undefined_messages).to eq(["undefined method `no_such_util' for singleton(Util)"])
  end

  it "still fires for self.class on a CLASS-typed receiver" do
    # The narrow keying, from the other side: `self.class` inside an ordinary class is
    # `Singleton[Widget]`, a surface RBS fully describes, and a typo there keeps reporting.
    write_project(<<~RUBY)
      class Widget
        def build = self.class.no_such_builder
      end
    RUBY
    expect(undefined_messages).to eq(["undefined method `no_such_builder' for singleton(Widget)"])
  end

  it "still fires for a typo on a class instance" do
    write_project(<<~RUBY)
      def run(widget)
        widget.no_such_method
      end

      def build = Widget.new.no_such_method
    RUBY
    expect(undefined_messages).to eq(["undefined method `no_such_method' for Widget"])
  end
end
