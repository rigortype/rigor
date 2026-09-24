# frozen_string_literal: true

require "prism"

require "rigor"
require "rigor/effects/scanner"

# The effects collection's include table is the instance ancestry that `super` and the constructor rule walk.
# `include`, `prepend` and `alias_method` are calls on `self`, and `alias` works on the default definee, so each
# reaches that ancestry only where the syntax shows `self` (or the definee) is the class. Where it is the singleton
# class, `include` does what `extend` does and an aliased `initialize` is a class method `new` never calls. Where the
# syntax does not say which class it is, the module or alias goes into a class the syntax does not name. Neither is
# recorded. Each snippet is evaluated as well as scanned, so every expectation here is also Ruby's answer.
RSpec.describe "which side an ancestry declaration in a class body reaches" do
  def scan(source)
    root = Prism.parse(source).value
    Rigor::Effects::Scanner.scan(root: root, path: "host.rb", calls: {}.compare_by_identity).includes
  end

  def evaluate(source)
    Module.new.tap { |namespace| namespace.module_eval(source, "host.rb") }
  end

  # body => whether Ruby puts `Mixin` in `Host`'s instance ancestry
  {
    "include Mixin" => true,
    "class_eval { include Mixin }" => true,
    # `instance_eval` moves the definee to the singleton class and leaves `self` the class.
    "instance_eval { include Mixin }" => true,
    "class << self; include Mixin; end" => false,
    "class << self; prepend Mixin; end" => false,
    "class << self; class << self; include Mixin; end; end" => false,
    "class << self; class_eval { include Mixin }; end" => false,
    "singleton_class.class_eval { include Mixin }" => false,
    "singleton_class.instance_eval { include Mixin }" => false,
    "singleton_class.instance_exec { include Mixin }" => false,
    # The block defines into a class the call creates, or into another class, and nothing names it here.
    "Class.new { include Mixin }" => false,
    "Struct.new(:a) { include Mixin }" => false,
    "Other.class_eval { include Mixin }" => false,
    "class << Other; include Mixin; end" => false
  }.each do |body, instance_side|
    %w[class module].each do |keyword|
      it "#{instance_side ? 'records' : 'does not record'} `#{body}` in a #{keyword} body" do
        source = "module Mixin; end\nclass Other; end\n#{keyword} Host\n  #{body}\nend\n"
        namespace = evaluate(source)
        expect(namespace.const_get(:Host).include?(namespace.const_get(:Mixin))).to be(instance_side)

        expect(scan(source).fetch("Host", []).include?("Mixin")).to be(instance_side)
      end
    end
  end

  # body => whether Ruby's alias defines the instance-side `initialize`, which the scan cannot read and so records
  # as the opaque sentinel
  {
    "def setup; end; alias initialize setup" => true,
    "def setup; end; alias_method :initialize, :setup" => true,
    "class << self; def setup; end; alias initialize setup; end" => false,
    "class << self; def setup; end; alias_method :initialize, :setup; end" => false,
    # The two spellings part here: `alias` follows the definee and `alias_method` follows `self`.
    "def self.setup; end; instance_eval { alias initialize setup }" => false,
    "def setup; end; instance_eval { alias_method :initialize, :setup }" => true,
    "Class.new { def setup; end; alias initialize setup }" => false,
    "Class.new { def setup; end; alias_method :initialize, :setup }" => false
  }.each do |body, instance_side|
    it "#{instance_side ? 'records' : 'does not record'} an unreadable constructor for `#{body}`" do
      source = "class Host\n  #{body}\nend\n"
      host = evaluate(source).const_get(:Host)
      expect(host.method_defined?(:initialize, false) || host.private_method_defined?(:initialize, false))
        .to be(instance_side)

      expect(scan(source).fetch("Host", []).include?(Rigor::Effects::FileCollection::OPAQUE_ANCESTOR))
        .to be(instance_side)
    end
  end

  # Ruby includes the module and aliases the constructor on `Host` itself, but the context reads `Host.class_eval`
  # inside `class Host` as an eval on any other receiver, so both are missed, as an `extend` is. Flip this when #1322
  # is fixed.
  it "misses an include and an alias through a class_eval on the class's own name" do
    source = "module Mixin; end\nclass Host\n  def setup; end\n  " \
             "Host.class_eval { include Mixin; alias_method :initialize, :setup }\nend\n"
    namespace = evaluate(source)
    host = namespace.const_get(:Host)
    expect(host.include?(namespace.const_get(:Mixin))).to be(true)
    expect(host.private_method_defined?(:initialize, false)).to be(true)

    expect(scan(source).fetch("Host", [])).to be_empty
  end
end
