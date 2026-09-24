# frozen_string_literal: true

require "prism"

require "rigor"
require "rigor/effects/scanner"

# The effects scanner keys a unit `Class.m` or `Class#m` and scans its body with a singleton bit, which decides
# `mutate.self` against `mutate.static` for a write to `self` and whether `new` on `self` is an allocation. Both
# are Ruby's answers, and Ruby takes them from different places. A bare `def` lands on the default definee, which a
# method body does not move, so `def inner` inside `def self.outer` defines `Widget#inner`. `define_method` and
# `attr_*` are calls on `self`, so inside `class << self` they define `Widget.x`, and inside `def self.setup` they
# define `Widget#x`. Where the syntax does not say which class a definition lands on, it is no unit at all.
#
# The fixture is evaluated as well as scanned, so every expectation here is also checked against what Ruby defines.
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

        # Definitions into a class the block builds, or into an object or class the syntax does not name.
        def self.define_elsewhere
          Class.new(self) do
            def plain_instance
              $probe = 1
              self
            end

            def in_class_new
              @probe = 1
              self
            end
          end
          Struct.new(:a) do
            def in_struct_new = self
          end
          ::Module.new do
            def in_module_new = self
          end
          Data.define(:a) do
            def in_data_define = self
          end
          other = Class.new
          other.class_eval do
            def in_foreign_class_eval = self
            define_method(:defined_in_foreign_class_eval) { self }
          end
          object = Object.new
          object.instance_eval do
            def in_foreign_instance_eval = self
          end
          def object.on_object = self
          object
        end

        def define_per_object
          def self.per_object
            @probe = 1
            self
          end
        end

        def define_instance_eigenclass
          class << self
            def in_instance_eigenclass = self
          end
        end

        def define_on_instance
          define_method(:defined_on_instance) { self }
        end

        class << Object.new
          def in_object_eigenclass = self
        end

        class << self
          attr_accessor :eigen_setting

          def eigen_singleton
            @probe = 1
            self
          end

          def self.meta_singleton = self

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

          instance_eval do
            def def_in_eigen_instance_eval = self

            define_method(:defined_in_eigen_instance_eval) do
              @probe = 1
              self
            end
          end
        end

        singleton_class.class_eval do
          attr_accessor :evaluated_setting

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

        self.singleton_class.module_exec do
          def def_in_singleton_module_exec
            @probe = 1
            self
          end
        end

        singleton_class.instance_eval do
          attr_accessor :instance_evaluated_setting

          def def_in_singleton_instance_eval = self

          define_method(:defined_in_singleton_instance_eval) do
            @probe = 1
            self
          end
        end

        instance_eval do
          attr_accessor :instance_eval_setting

          def def_in_instance_eval
            @probe = 1
            self
          end

          define_method(:defined_in_instance_eval) do
            @probe = 1
            self
          end

          class_eval do
            def def_in_class_eval_in_instance_eval
              @probe = 1
              self
            end
          end
        end

        instance_exec do
          def def_in_instance_exec
            @probe = 1
            self
          end
        end

        self.class_eval do
          def def_in_self_class_eval
            @probe = 1
            self
          end
        end

        module_eval do
          def def_in_module_eval
            @probe = 1
            self
          end
        end
      end

      module Gadget
        class << self
          attr_accessor :level

          define_method(:defined_in_module_eigenclass) do
            @probe = 1
            self
          end
        end

        def self.install
          def nested_in_module_singleton_method
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
       define_from_eigen_method define_from_eigen_block define_elsewhere]
  end

  let(:namespace) do
    Module.new.tap do |namespace|
      namespace.module_eval(fixture, "widget.rb")
      widget = namespace.const_get(:Widget)
      definers.each { |definer| widget.public_send(definer) }
      namespace.const_get(:Gadget).install
    end
  end

  let(:widget) { namespace.const_get(:Widget) }

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

  # Every fixture method returns `self`, so running it says what its body runs on. A module's instance method runs
  # on an object the module is mixed into.
  def runs_on_class?(mod, name, side)
    receiver = if side == "." then mod
               elsif mod.is_a?(Class) then mod.allocate
               else Object.new.extend(mod)
               end
    receiver.public_send(name).is_a?(Module)
  end

  def scanned_keys(owner, name)
    summaries.keys.grep(/\A#{owner}[#.]#{Regexp.escape(name)}\z/)
  end

  def labels(key, origin)
    summaries.fetch(key).bundles.fetch(Rigor::Effects::Origin.construct(origin)).to_a
  end

  # key => whether its body runs on the class
  {
    "Widget#plain_instance" => false,
    "Widget.plain_singleton" => true,
    # A method body does not move the default definee, and neither does an ordinary block inside one.
    "Widget#nested_in_singleton_method" => false,
    "Widget#nested_in_singleton_method_block" => false,
    # `define_method` is a call on `self`, and `self` in a singleton method is the class.
    "Widget#defined_in_singleton_method" => false,
    # Inside `class << self` both the default definee and `self` are the singleton class.
    "Widget.eigen_singleton" => true,
    "Widget.defined_in_eigenclass" => true,
    # A method of `class << self` runs on the class, while it keeps the singleton class as its definee.
    "Widget.nested_in_eigen_method" => true,
    "Widget#defined_in_eigen_method" => false,
    "Widget#def_in_eigen_method_class_eval" => false,
    # A `define_method` block keeps the definee it closed over.
    "Widget.nested_in_eigen_block" => true,
    # `class_eval` on the singleton class makes it `self` and the definee, as `class << self` does.
    "Widget.def_in_singleton_class_eval" => true,
    "Widget.defined_in_singleton_class_eval" => true,
    "Widget.def_in_singleton_class_exec" => true,
    "Widget.def_in_singleton_module_exec" => true,
    "Widget.def_in_method_singleton_class_eval" => true,
    "Widget.def_in_method_eigenclass" => true,
    # `instance_eval` moves the definee to the singleton class of `self`, and leaves `self` where it was.
    "Widget.def_in_instance_eval" => true,
    "Widget.def_in_instance_exec" => true,
    "Widget#defined_in_instance_eval" => false,
    "Widget#def_in_class_eval_in_instance_eval" => false,
    "Widget.defined_in_singleton_instance_eval" => true,
    "Widget.defined_in_eigen_instance_eval" => true,
    "Widget#def_in_self_class_eval" => false,
    "Widget#def_in_module_eval" => false,
    "Gadget.defined_in_module_eigenclass" => true,
    "Gadget#nested_in_module_singleton_method" => false
  }.each do |key, on_class|
    it "keys #{key}, with the body running on #{on_class ? 'the class' : 'an instance'}" do
      owner, side, name = key.match(/\A(\w+)([#.])(\w+)\z/).captures
      mod = namespace.const_get(owner)
      expect(ruby_side(mod, name.to_sym)).to eq(side)
      expect(runs_on_class?(mod, name.to_sym, side)).to eq(on_class)

      expect(scanned_keys(owner, name)).to eq([key])
      expect(labels(key, "ivar-write")).to eq([on_class ? "mutate.static" : "mutate.self"])
    end
  end

  it "keys an attr_accessor on the side `define_method` would take there, a singleton writer writing the class" do
    {
      "Widget#setting" => "#", "Widget.eigen_setting" => ".", "Widget.evaluated_setting" => ".",
      "Widget.instance_evaluated_setting" => ".", "Widget#instance_eval_setting" => "#", "Gadget.level" => "."
    }.each do |key, side|
      owner, name = key.split(/[#.]/)
      expect([ruby_side(namespace.const_get(owner), name.to_sym),
              ruby_side(namespace.const_get(owner), :"#{name}=")]).to eq([side, side]), key
      expect(scanned_keys(owner, name) + scanned_keys(owner, "#{name}=")).to eq([key, "#{key}="])
      expect(summaries.fetch("#{key}=").proven.to_a).to eq([side == "." ? "mutate.static" : "mutate.self"])
    end
  end

  # Filed under the enclosing class, each of these would join a real method of that class — and a `Class.new(self)`
  # subclass overrides the parent's methods by design, so the collision is the common case, not a coincidence.
  it "keys no unit for a definition into a class a block builds, or into a receiver the syntax does not name" do
    %w[in_class_new in_struct_new in_module_new in_data_define in_foreign_class_eval defined_in_foreign_class_eval
       in_foreign_instance_eval on_object in_object_eigenclass].each do |name|
      expect(ruby_side(widget, name.to_sym)).to be_nil, name
      expect(scanned_keys("Widget", name)).to eq([]), name
    end

    expect(widget.new.plain_instance).to be_a(widget)
    expect(summaries.fetch("Widget#plain_instance").proven.to_a).to eq(["mutate.self"])
  end

  # A method on one object, or on the singleton class's own singleton class, has no key.
  it "keys no unit for a method defined on one object or on the singleton class's singleton class" do
    instance = widget.new
    instance.define_per_object
    instance.define_instance_eigenclass

    expect(instance.singleton_methods).to contain_exactly(:per_object, :in_instance_eigenclass)
    expect(instance.per_object).to equal(instance)
    expect { widget.new.define_on_instance }.to raise_error(NoMethodError)
    %i[meta_singleton def_in_singleton_instance_eval def_in_eigen_instance_eval].each do |name|
      expect(defined_on?(widget.singleton_class.singleton_class, name)).to be(true), name.to_s
    end

    %w[per_object in_instance_eigenclass defined_on_instance meta_singleton def_in_singleton_instance_eval
       def_in_eigen_instance_eval].each do |name|
      expect(ruby_side(widget, name.to_sym)).to be_nil, name
      expect(scanned_keys("Widget", name)).to eq([]), name
    end
  end

  # At the top level `self` is `main`, an instance of `Object`: a `def` there is a private method of `Object`, and a
  # `def self.x` or `class << self` defines on `main` alone. (Not evaluated here, since that would define on the
  # suite's own `main`.)
  it "keys a top-level def on the instance side, and no unit for one defined on main" do
    root = Prism.parse(<<~RUBY).value
      def top_plain
        @probe = 1
      end

      def self.top_single = 1

      class << self
        def top_eigen = 1
      end

      instance_eval do
        def top_instance_eval = 1
      end
    RUBY
    summaries = Rigor::Effects::Scanner.scan(root: root, path: "top.rb", calls: {}.compare_by_identity).summaries

    expect(summaries.keys).to eq(["<toplevel>#top_plain"])
    expect(summaries.fetch("<toplevel>#top_plain").proven.to_a).to eq(["mutate.self"])
  end
end
