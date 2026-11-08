# frozen_string_literal: true

# Issue #2986 — a computed-definer class macro declared in an ActiveSupport::Concern's `class_methods do … end` block
# opens the instance side of the concern's direct includer, as #2975's `self.included(base) = base.extend(ClassMethods)`
# hook does: `Concern#append_features` extends the includer with the `ClassMethods` module the block builds. Each
# row's Ruby behaviour was witnessed on Ruby 4.0.5 with activesupport 8.1.4 loaded (`require "active_support/concern"`,
# left out of the sources here since the walk reads syntax only).

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "ActiveSupport::Concern class_methods macros and call.undefined-method (#2986)" do
  # Every top-level class and module the sources write gets an empty `sig/` declaration, unless `sig:` gives the
  # declarations.
  def write_project(source, calls, extra_files: {}, sig: nil)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    declared = ([source] + extra_files.values).flat_map { |body| body.scan(/^(class|module) (\w+)/) }.uniq
    sig ||= declared.map { |kind, name| "#{kind} #{name}\nend\n" }.join
    File.write(File.join("sig", "types.rbs"), sig)
    File.write(File.join("lib", "defs.rb"), source)
    extra_files.each { |name, body| File.write(File.join("lib", name), body) }
    File.write(File.join("lib", "caller.rb"), "def run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  around do |example|
    Dir.mktmpdir("rigor-concern-class-methods-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def definer_body = "n.each { |x| define_method(x) { x } }"

  def concern(name, body: definer_body, extend_line: "extend ActiveSupport::Concern")
    "module #{name}\n  #{extend_line}\n  class_methods do\n    def my_c(*n) = #{body}\n  end\nend\n"
  end

  it "opens the instance side of the includer" do
    write_project("#{concern('Conc9')}class C9\n  include Conc9\n  my_c :c9\nend\n", %w[C9.new.c9])
    expect(undefined_messages).to be_empty
  end

  it "opens an includer in another file" do
    write_project("class C10\n  include Conc10\n  my_c :c10\nend\n", %w[C10.new.c10],
                  extra_files: { "conc.rb" => concern("Conc10") })
    expect(undefined_messages).to be_empty
  end

  it "opens a prepending class, which Concern#prepend_features extends the same way" do
    write_project("#{concern('Conc11')}class C11\n  prepend Conc11\n  my_c :c11\nend\n", %w[C11.new.c11])
    expect(undefined_messages).to be_empty
  end

  it "reads `extend Concern` in a module nested in ActiveSupport" do
    source = "module ActiveSupport\n  #{concern('Conc12', extend_line: 'extend Concern').gsub("\n", "\n  ")}end\n" \
             "class C12\n  include ActiveSupport::Conc12\n  my_c :c12\nend\n"
    write_project(source, %w[C12.new.c12], sig: "module ActiveSupport\n  module Conc12\n  end\nend\nclass C12\nend\n")
    expect(undefined_messages).to be_empty
  end

  it "opens the includer when an included block calls the macro" do
    source = "module Conc13\n  extend ActiveSupport::Concern\n  class_methods do\n    " \
             "def my_c(*n) = #{definer_body}\n  end\n  included do\n    my_c :c13\n  end\nend\n" \
             "class C13\n  include Conc13\nend\n"
    write_project(source, %w[C13.new.c13])
    expect(undefined_messages).to be_empty
  end

  # Guard: the includer was already open on master without its sig (#2094's concern rule); pins that it stays so.
  it "keeps the includer open when no sig declares it" do
    write_project("#{concern('Conc14')}class C14\n  include Conc14\n  my_c :c14\nend\n", %w[C14.new.c14], sig: "")
    expect(undefined_messages).to be_empty
  end

  # Guard: pins the reporting side; no removed line of the fix makes it pass for the wrong reason.
  it "does not open an includer whose class_methods macro defines nothing" do
    write_project("#{concern('Conc15', body: 'n')}class C15\n  include Conc15\n  my_c :c15\nend\n", %w[C15.new.c15])
    expect(undefined_messages).to eq(["undefined method `c15' for C15"])
  end

  # Without `extend ActiveSupport::Concern` the module's own `class_methods` (here a stub that ignores its block, so the
  # source runs) builds no `ClassMethods`, and the includer's own `my_c` defines nothing.
  it "does not read a class_methods block of a module that does not extend ActiveSupport::Concern" do
    source = "#{concern('Conc16', extend_line: 'def self.class_methods(&) = nil')}" \
             "class C16\n  include Conc16\n  def self.my_c(*n) = n\n  my_c :c16\nend\n"
    write_project(source, %w[C16.new.c16])
    expect(undefined_messages).to eq(["undefined method `c16' for C16"])
  end

  # Concern#append_features extends the includer with `Outer18.const_get(:ClassMethods)`, which finds the included
  # concern's `ClassMethods` through `Outer18`'s ancestors.
  it "reads a concern included into another concern that has no ClassMethods of its own" do
    source = "#{concern('Conc17')}module Outer17\n  extend ActiveSupport::Concern\n  include Conc17\nend\n" \
             "class C17\n  include Outer17\n  my_c :c17\nend\n"
    write_project(source, %w[C17.new.c17])
    expect(undefined_messages).to be_empty
  end

  # Known limit: Concern also collects an included concern as a dependency of the final includer and extends it with
  # that concern's `ClassMethods`; the reader follows `const_get(:ClassMethods)` only, which stops at the outer
  # concern's own `ClassMethods`, so this still reports.
  it "does not yet read a dependency concern when the outer concern has its own ClassMethods" do
    source = "#{concern('Conc18')}#{concern('Outer18', body: 'n').sub("module Outer18\n", "module Outer18\n  include Conc18\n")}" \
             "class C18\n  include Outer18\n  my_c :c18\nend\n"
    write_project(source, %w[C18.new.c18])
    expect(undefined_messages).to eq(["undefined method `c18' for C18"])
  end

  # The `included` and `prepended` blocks run only for their own edge. In the rows that report, a superclass's
  # `my_c`, which defines nothing, lets the class body run in Ruby.
  def hook_concern(name, hook)
    "module #{name}\n  extend ActiveSupport::Concern\n  class_methods do\n    def my_c(*n) = #{definer_body}\n  end\n" \
      "  #{hook} do\n    my_c :#{name.downcase}\n  end\nend\n"
  end

  def quiet_base(name) = "class #{name}\n  def self.my_c(*n) = n\nend\n"

  it "opens a prepending class when a prepended block calls the macro" do
    write_project("#{hook_concern('Hp1', 'prepended')}class Hp1c\n  prepend Hp1\nend\n", %w[Hp1c.new.hp1])
    expect(undefined_messages).to be_empty
  end

  it "does not read an included block for a prepending class" do
    write_project("#{hook_concern('Hp2', 'included')}class Hp2c\n  prepend Hp2\nend\n", %w[Hp2c.new.hp2])
    expect(undefined_messages).to eq(["undefined method `hp2' for Hp2c"])
  end

  it "does not read a prepended block for an including class" do
    write_project("#{hook_concern('Hp3', 'prepended')}class Hp3c\n  include Hp3\nend\n", %w[Hp3c.new.hp3])
    expect(undefined_messages).to eq(["undefined method `hp3' for Hp3c"])
  end

  it "reads a self.-receiver macro call in an included block" do
    source = hook_concern("Hp6", "included").sub("    my_c :hp6", "    self.my_c :hp6")
    write_project("#{source}class Hp6c\n  include Hp6\nend\n", %w[Hp6c.new.hp6])
    expect(undefined_messages).to be_empty
  end

  # The call runs in an instance method the block defines, on an instance, and only when that method is called.
  it "does not read a macro call in a def of an included block" do
    source = hook_concern("Hp5", "included").sub("    my_c :hp5", "    def later = my_c(:hp5)")
    write_project("#{source}class Hp5c\n  include Hp5\nend\n", %w[Hp5c.new.hp5])
    expect(undefined_messages).to eq(["undefined method `hp5' for Hp5c"])
  end

  # The concern's own `my_c` here defines nothing, so its body call loads; Ruby never runs it for the includer.
  it "does not read a macro call in the concern's own module body" do
    source = "module Hp4\n  extend ActiveSupport::Concern\n  def self.my_c(*n) = n\n  class_methods do\n    " \
             "def my_c(*n) = #{definer_body}\n  end\n  my_c :hp4\nend\nclass Hp4c\n  include Hp4\nend\n"
    write_project(source, %w[Hp4c.new.hp4])
    expect(undefined_messages).to eq(["undefined method `hp4' for Hp4c"])
  end

  describe "the ClassMethods a concern extends its includer with" do
    it "is not looked up in the namespace enclosing the concern" do
      source = "module Nj\n  module ClassMethods\n    def my_c(*n) = #{definer_body}\n  end\n  module Co\n    " \
               "extend ActiveSupport::Concern\n    def co = 1\n  end\nend\n#{quiet_base('Bj')}class Cj < Bj\n  include Nj::Co\n  " \
               "my_c :cj\nend\n"
      sig = "module Nj\n  module ClassMethods\n  end\n  module Co\n  end\nend\nclass Bj\nend\nclass Cj < Bj\nend\n"
      write_project(source, %w[Cj.new.cj], sig: sig)
      expect(undefined_messages).to eq(["undefined method `cj' for Cj"])
    end

    it "is the top-level ClassMethods when the concern has none" do
      source = "module ClassMethods\n  def my_c(*n) = #{definer_body}\nend\nmodule Ct\n  extend ActiveSupport::Concern\n  def ct_own = 1\n" \
               "end\nclass Ctc\n  include Ct\n  my_c :ct\nend\n"
      write_project(source, %w[Ctc.new.ct])
      expect(undefined_messages).to be_empty
    end

    it "is an explicit module ClassMethods of a concern that defines methods of its own" do
      source = "module Ra\n  extend ActiveSupport::Concern\n  def ra = 1\n  module ClassMethods\n    " \
               "def my_c(*n) = #{definer_body}\n  end\nend\nclass Ka\n  include Ra\n  my_c :ka\nend\n"
      write_project(source, %w[Ka.new.ka])
      expect(undefined_messages).to be_empty
    end

    # Guard: the control for the explicit ClassMethods row.
    it "does not open the includer when that explicit ClassMethods macro defines nothing" do
      source = "module Rb\n  extend ActiveSupport::Concern\n  def rb = 1\n  module ClassMethods\n    " \
               "def my_c(*n) = n\n  end\nend\nclass Kb\n  include Rb\n  my_c :kb\nend\n"
      write_project(source, %w[Kb.new.kb])
      expect(undefined_messages).to eq(["undefined method `kb' for Kb"])
    end
  end

  # Each `def` here defines on another module than `ClassMethods`, or not until something calls it. The concern
  # defines a method of its own here, as in the namespace row: a concern with none already opens its includer (#2094).
  # The `def self.` row is a guard: the def's receiver gives it the singleton side in the recorders it shares with
  # every `def`, and no line of the concern read decides it.
  describe "a def a class_methods block does not define on ClassMethods" do
    {
      "a def self. method" => "def self.my_c(*n) = DEF",
      "a def in a nested class" => "class Inner\n      def my_c(*n) = DEF\n    end",
      "a def in a nested module" => "module InnerM\n      def my_c(*n) = DEF\n    end",
      "a def in a class << self body" => "class << self\n      def my_c(*n) = DEF\n    end",
      "a def in a Module.new block" => "Module.new do\n      def my_c(*n) = DEF\n    end",
      "a def in a lambda" => "@later = -> { def my_c(*n) = DEF }"
    }.each_with_index do |(label, body), index|
      it "does not open the includer for #{label}" do
        name = "Nd#{index}"
        source = "module #{name}\n  extend ActiveSupport::Concern\n  def own = 1\n  class_methods do\n    " \
                 "#{body.gsub('DEF', definer_body)}\n  end\nend\n#{quiet_base("B#{name}")}" \
                 "class C#{name} < B#{name}\n  include #{name}\n  my_c :x#{index}\nend\n"
        write_project(source, ["C#{name}.new.x#{index}"])
        expect(undefined_messages).to eq(["undefined method `x#{index}' for C#{name}"])
      end
    end
  end
end
