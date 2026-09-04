# frozen_string_literal: true

# Issue #742 — a value typed `Class` or `Module` is SOME class or module object, and its singleton methods
# cannot be enumerated from the metaclass.
#
# `def self.included(base)` receives the includer, so `base.class_attribute :main_menu` and
# `base.main_menu = true` are calls on whatever included the module — redmine's `MenuController` writes
# exactly that. The union rule has declined these arms since it was written (`METACLASS_ARMS`: "a
# `plugin_class : Class` really holds a `Plugin` subclass with `.manifest`"); the scalar rule enumerated
# `Module`'s own RBS instead and reported them.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a Class / Module receiver and call.undefined-method (#742)" do
  def write_project(source)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "menu.rbs"), <<~RBS)
      module MenuController
        def self.included: (Module base) -> void
      end
      module Registry
        def self.register: (Class klass) -> void
      end
      class Widget
      end
    RBS
    File.write(File.join("lib", "menu.rb"), source)
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
    Dir.mktmpdir("rigor-metaclass-receiver-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not fire on a Module-typed receiver" do
    write_project(<<~RUBY)
      module MenuController
        def self.included(base)
          base.class_attribute :main_menu
          base.main_menu = true
        end
      end
    RUBY
    expect(undefined_messages).to be_empty
  end

  it "does not fire on a Class-typed receiver" do
    write_project(<<~RUBY)
      module Registry
        def self.register(klass)
          klass.configure_everything
        end
      end
    RUBY
    expect(undefined_messages).to be_empty
  end

  it "still fires on a named singleton receiver" do
    # Mandatory must-still-fire: `Widget` names one class whose singleton surface RBS describes, which is
    # not the same thing as a value typed `Class`. Without this arm the stand-down could have been written
    # over every `Singleton[*]` receiver and passed.
    write_project(<<~RUBY)
      class Widget
        def build = Widget.no_such_singleton
      end
    RUBY
    expect(undefined_messages).to eq(
      ["undefined method `no_such_singleton' for singleton(Widget)"]
    )
  end
end
