# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "fileutils"

# Issue #1931 — the ADR-58 class-ivar census (`ScopeIndexer#build_class_ivar_index`) did not see an
# `instance_variable_set` on `self`, so a reader in another method kept the literal a plain write left (`@timeout = 5`
# read as `5`) and reported a call on it, although `Client.new(timeout: "10s")` sets a String. A literal name now
# contributes the value's type to that ivar's entry; a computed name makes every entry of the class gradual.
RSpec.describe "the ADR-58 ivar census counts instance_variable_set writes" do
  def census(source, class_name, ivar)
    program = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    index[program].class_ivars_for(class_name)[ivar]&.describe
  end

  def diagnostics_for(source)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "client.rb"), source)
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]),
        cache_store: nil
      )
      guarded_run(runner).diagnostics
                         .reject { |d| d.path.to_s.end_with?(".rigor.yml") }
                         .map { |d| [d.line, d.rule] }
    end
  end

  describe "a literal name" do
    {
      "a Symbol" => "instance_variable_set(:@k, 5)",
      "a String" => %(instance_variable_set("@k", 5)),
      "an explicit self receiver" => "self.instance_variable_set(:@k, 5)",
      "a call inside a block" => "[1].each { instance_variable_set(:@k, 5) }"
    }.each do |shape, call|
      it "joins the value's type for #{shape}" do
        source = "class K\n  def initialize = @k = 0\n  def set = #{call}\nend\n"

        expect(census(source, "K", :@k)).to eq("0 | 5")
      end
    end

    it "creates the entry for an ivar no plain write names" do
      source = %(class K\n  def set = instance_variable_set(:@only, "s")\nend\n)

      expect(census(source, "K", :@only)).to eq(%("s"))
    end
  end

  describe "a name the analysis cannot read" do
    {
      "an interpolated Symbol" => %(instance_variable_set(:"@\#{k}", 1)),
      "a local" => "instance_variable_set(k, 1)",
      "a splat" => "instance_variable_set(*k)"
    }.each do |shape, call|
      it "makes every entry of the class gradual for #{shape}" do
        source = "class K\n  def initialize = @a = 0\n  def other = @b = \"s\"\n  def set(k) = #{call}\nend\n"

        expect([census(source, "K", :@a), census(source, "K", :@b)]).to eq(%w[Dynamic[top] Dynamic[top]])
      end
    end

    it "leaves another class alone" do
      source = "class K\n  def set(k) = instance_variable_set(k, 1)\nend\nclass L\n  def initialize = @a = 0\nend\n"

      expect(census(source, "L", :@a)).to eq("0")
    end

    it "does not count another object's instance_variable_set" do
      source = "class K\n  def initialize = @a = 0\n  def set(o, k) = o.instance_variable_set(k, 1)\nend\n"

      expect(census(source, "K", :@a)).to eq("0")
    end
  end

  it "no longer reports a call on the literal a plain write left (the options-hash constructor)" do
    source = <<~RUBY
      class Client
        def initialize(options = {})
          @timeout = 5
          options.each { |k, v| instance_variable_set(:"@\#{k}", v) }
        end

        def show = @timeout.end_with?("s")
      end
    RUBY

    expect(diagnostics_for(source)).to eq([])
  end

  it "keeps reporting a call on an ivar of a class with no reflective write" do
    source = "class Plain\n  def initialize = @n = 1\n  def show = @n.no_such_method\nend\n"

    expect(diagnostics_for(source)).to include([3, "call.undefined-method"])
  end
end
