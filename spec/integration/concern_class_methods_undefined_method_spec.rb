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

  # Known limit: Concern collects a concern included into another concern as a dependency and extends the final
  # includer with its `ClassMethods` too; the reader reads the direct includer's own mixins only, so this still reports.
  it "does not yet read a concern included through another concern" do
    source = "#{concern('Conc17')}module Outer17\n  extend ActiveSupport::Concern\n  include Conc17\nend\n" \
             "class C17\n  include Outer17\n  my_c :c17\nend\n"
    write_project(source, %w[C17.new.c17])
    expect(undefined_messages).to eq(["undefined method `c17' for C17"])
  end
end
