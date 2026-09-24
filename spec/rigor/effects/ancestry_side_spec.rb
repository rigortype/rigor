# frozen_string_literal: true

require "prism"

require "rigor"
require "rigor/effects/scanner"

# The effects collection's include table is the instance ancestry that `super` and the constructor rule walk.
# `include`, `prepend` and `alias_method` are calls on `self`, and `alias` works on the default definee, so each
# reaches that ancestry only where `self` (or the definee) is the class. Where it is the singleton class, `include`
# does what `extend` does and an aliased `initialize` is a class method `new` never calls, so neither is recorded.
# Each snippet is evaluated as well as scanned, so every expectation here is also Ruby's answer.
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
    "singleton_class.class_eval { include Mixin }" => false
  }.each do |body, instance_side|
    %w[class module].each do |keyword|
      it "#{instance_side ? 'records' : 'does not record'} `#{body}` in a #{keyword} body" do
        source = "module Mixin; end\n#{keyword} Host\n  #{body}\nend\n"
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
    "def setup; end; instance_eval { alias_method :initialize, :setup }" => true
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
end
