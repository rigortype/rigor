# frozen_string_literal: true

require "prism"

require "rigor"
require "rigor/effects/scanner"

# The effects scanner keys a unit `Class.m` or `Class#m` and scans its body with a singleton bit, which decides
# `mutate.self` against `mutate.static` for a write to `self` and whether `new` on `self` is an allocation. Both
# are Ruby's answers, and Ruby takes them from different places. A bare `def` lands on the default definee, which a
# method body does not move, so `def inner` inside `def self.outer` defines `Widget#inner`. `define_method` and
# `attr_*` are calls on `self`, so inside `class << self` they define `Widget.x`, and inside `def self.setup` they
# define `Widget#x`.
#
# The scanner read the enclosing method's bit for the first and ignored `class << self` for the second. The
# fixture is evaluated as well as scanned, so every expectation here is also checked against what Ruby defines.
RSpec.describe "the side an effect unit is keyed on" do
  let(:fixture) do
    <<~RUBY
      class Widget
        attr_accessor :setting

        def plain_instance
          @probe = 1
          self
        end

        def self.plain_singleton
          @probe = 1
          self
        end

        def self.define_nested
          def nested_in_singleton_method
            @probe = 1
            self
          end
        end

        def self.define_by_call
          define_method(:defined_in_singleton_method) do
            @probe = 1
            self
          end
        end

        def self.define_in_block
          [1].each do
            def nested_in_singleton_method_block
              @probe = 1
              self
            end
          end
        end

        def self.define_through_singleton_class_eval
          singleton_class.class_eval do
            def def_in_method_singleton_class_eval
              @probe = 1
              self
            end
          end
        end

        def self.define_through_eigenclass
          class << self
            def def_in_method_eigenclass
              @probe = 1
              self
            end
          end
        end

        def define_per_object
          def self.per_object
            @probe = 1
            self
          end
        end

        class << self
          attr_accessor :eigen_setting

          def eigen_singleton
            @probe = 1
            self
          end

          define_method(:defined_in_eigenclass) do
            @probe = 1
            self
          end

          def define_from_eigen_method
            def nested_in_eigen_method
              @probe = 1
              self
            end

            define_method(:defined_in_eigen_method) do
              @probe = 1
              self
            end

            class_eval do
              def def_in_eigen_method_class_eval
                @probe = 1
                self
              end
            end
          end

          define_method(:define_from_eigen_block) do
            def nested_in_eigen_block
              @probe = 1
              self
            end
          end
        end

        singleton_class.class_eval do
          def def_in_singleton_class_eval
            @probe = 1
            self
          end

          define_method(:defined_in_singleton_class_eval) do
            @probe = 1
            self
          end
        end

        singleton_class.class_exec do
          def def_in_singleton_class_exec
            @probe = 1
            self
          end
        end

        instance_eval do
          def def_in_instance_eval
            @probe = 1
            self
          end

          define_method(:defined_in_instance_eval) do
            @probe = 1
            self
          end
        end

        class_eval do
          def def_in_class_eval
            @probe = 1
            self
          end
        end
      end
    RUBY
  end

  # The singleton methods whose bodies define the nested shapes when they run.
  let(:definers) do
    %i[define_nested define_by_call define_in_block define_through_singleton_class_eval define_through_eigenclass
       define_from_eigen_method define_from_eigen_block]
  end

  let(:widget) do
    namespace = Module.new
    namespace.module_eval(fixture, "widget.rb")
    namespace.const_get(:Widget).tap { |widget| definers.each { |definer| widget.public_send(definer) } }
  end

  let(:summaries) do
    root = Prism.parse(fixture).value
    Rigor::Effects::Scanner.scan(root: root, path: "widget.rb", calls: {}.compare_by_identity).summaries
  end

  # `#` or `.` — which side of `klass` Ruby defined `name` on — or nil when it is on neither.
  def ruby_side(klass, name)
    if defined_on?(klass, name) then "#"
    elsif defined_on?(klass.singleton_class, name) then "."
    end
  end

  def defined_on?(mod, name)
    mod.method_defined?(name, false) || mod.private_method_defined?(name, false)
  end

  # Every fixture method returns `self`, so running it says what its body runs on.
  def runs_on_class?(klass, name, side)
    (side == "." ? klass : klass.allocate).public_send(name).is_a?(Module)
  end

  def scanned_keys(name)
    summaries.keys.grep(/\AWidget[#.]#{Regexp.escape(name)}\z/)
  end

  def ivar_write(key)
    summaries.fetch(key).bundles.fetch(Rigor::Effects::Origin.construct("ivar-write")).to_a
  end

  # name => [the side Ruby defines it on, whether its body runs on the class]
  {
    "plain_instance" => ["#", false],
    "plain_singleton" => [".", true],
    # A method body does not move the default definee, and neither does an ordinary block inside one.
    "nested_in_singleton_method" => ["#", false],
    "nested_in_singleton_method_block" => ["#", false],
    # `define_method` is a call on `self`, and `self` in a singleton method is the class.
    "defined_in_singleton_method" => ["#", false],
    # Inside `class << self` both the default definee and `self` are the singleton class.
    "eigen_singleton" => [".", true],
    "defined_in_eigenclass" => [".", true],
    # A method of `class << self` runs on the class, while it keeps the singleton class as its definee.
    "nested_in_eigen_method" => [".", true],
    "defined_in_eigen_method" => ["#", false],
    "def_in_eigen_method_class_eval" => ["#", false],
    # A `define_method` block keeps the definee it closed over.
    "nested_in_eigen_block" => [".", true],
    # `class_eval` on the singleton class makes it `self` and the definee, as `class << self` does.
    "def_in_singleton_class_eval" => [".", true],
    "defined_in_singleton_class_eval" => [".", true],
    "def_in_singleton_class_exec" => [".", true],
    "def_in_method_singleton_class_eval" => [".", true],
    "def_in_method_eigenclass" => [".", true],
    # `instance_eval` moves the definee to the singleton class and leaves `self` the class.
    "def_in_instance_eval" => [".", true],
    "defined_in_instance_eval" => ["#", false],
    "def_in_class_eval" => ["#", false]
  }.each do |name, (side, on_class)|
    it "keys #{name} as Widget#{side}#{name}, with the body running on #{on_class ? 'the class' : 'an instance'}" do
      expect(ruby_side(widget, name.to_sym)).to eq(side)
      expect(runs_on_class?(widget, name.to_sym, side)).to eq(on_class)

      expect(scanned_keys(name)).to eq(["Widget#{side}#{name}"])
      expect(ivar_write("Widget#{side}#{name}")).to eq([on_class ? "mutate.static" : "mutate.self"])
    end
  end

  it "keys an attr_accessor inside `class << self` on the singleton side, its writer a write to the class" do
    expect([ruby_side(widget, :eigen_setting), ruby_side(widget, :eigen_setting=)]).to eq(%w[. .])
    expect([ruby_side(widget, :setting), ruby_side(widget, :setting=)]).to eq(%w[# #])

    expect(scanned_keys("eigen_setting") + scanned_keys("eigen_setting=")).to eq(%w[Widget.eigen_setting
                                                                                    Widget.eigen_setting=])
    expect(summaries.fetch("Widget.eigen_setting=").proven.to_a).to eq(["mutate.static"])
    expect(summaries.fetch("Widget#setting=").proven.to_a).to eq(["mutate.self"])
  end

  # No key names a method defined on one object, so the key stays the singleton one it always was. The body runs on
  # that object, an instance, and is scanned as one: this is the shape whose key and body bit differ.
  it "keeps a `def self.x` in an instance method keyed singleton, with the body running on the instance" do
    instance = widget.new
    instance.define_per_object

    expect(instance.singleton_methods).to eq([:per_object])
    expect(ruby_side(widget, :per_object)).to be_nil
    expect(instance.per_object).to equal(instance)

    expect(scanned_keys("per_object")).to eq(["Widget.per_object"])
    expect(ivar_write("Widget.per_object")).to eq(["mutate.self"])
  end
end
