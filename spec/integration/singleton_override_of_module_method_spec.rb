# frozen_string_literal: true

require "spec_helper"

# Issue #2284 — a project singleton definer of a name `Module` / `Class` also declares (`def self.name`) answers a
# call on the class object, not the `Singleton[Object]` fallback's `Module#name -> String`: Ruby's singleton
# ancestry puts every project entry ahead of `Class`. Each example's comment is Ruby 4.0.5's value of the call.
RSpec.describe "a project singleton override of a Module method wins on the class object (#2284)", type: :runner do
  def dumps(source = nil, files: {})
    result = files.empty? ? analyze(source) : analyze(files: files)
    dumped = result.diagnostics.select { |d| d.qualified_rule == "dump.type" }
    dumped.map { |d| d.message.delete_prefix("dump_type: ") }
  end

  def undefined_methods(source)
    analyze(source).diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  it "types the call from the class's own def self.name and reports nothing on the result" do
    expect(dumps(<<~RUBY)).to eq(%w[42 42 42])
      class Base2; def self.name = 42; end
      Rigor.dump_type(Base2.name) # 42
      Rigor.dump_type(Base2.new.class.name) # 42
      class Sub < Base2; end
      Rigor.dump_type(Sub.name) # 42, inherited
    RUBY
    expect(undefined_methods(<<~RUBY)).to eq([])
      class Base2; def self.name = 42; end
      Base2.name.even?
    RUBY
  end

  it "types the call from a class << self body, a module's def self.name and an extended module" do
    expect(dumps(<<~RUBY)).to eq(%w[43 44 45])
      class Cs; class << self; def name = 43; end; end
      module M1; def self.name = 44; end
      module N; def name = 45; end
      class Ce; extend N; end
      Rigor.dump_type(Cs.name) # 43
      Rigor.dump_type(M1.name) # 44
      Rigor.dump_type(Ce.name) # 45
    RUBY
  end

  it "keeps String where only the instance side defines the name, and where nothing does (controls)" do
    expect(dumps(<<~RUBY)).to eq(%w[String String])
      class Foo; def name = 1; end
      class Bar; end
      Rigor.dump_type(Foo.name) # "Foo"
      Rigor.dump_type(Bar.name.upcase) # "BAR"
    RUBY
  end

  # The def may not run, so neither its type nor String alone is the answer.
  it "does not answer String alone for a def behind a condition" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"])
      class Cond; def self.name = 46 if ENV["Q"]; end
      Rigor.dump_type(Cond.name) # "Cond" (Q unset)
    RUBY
  end

  it "resolves an override written in another file, and keeps a sibling's same-named override to its class" do
    expect(dumps(files: {
                   "base.rb" => "class Base3; def self.name = 42; end\n",
                   "other.rb" => "class Other3; def self.name = :other; end\n",
                   "sub.rb" => "class Sub3 < Base3; end\n",
                   "use.rb" => <<~RUBY
                     class Plain3; end
                     Rigor.dump_type(Base3.name) # 42
                     Rigor.dump_type(Sub3.name) # 42
                     Rigor.dump_type(Plain3.name) # "Plain3"
                   RUBY
                 })).to eq(%w[42 42 String])
  end
end
