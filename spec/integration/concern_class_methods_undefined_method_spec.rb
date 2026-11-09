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

  # In Ruby, `Conc17.append_features(Outer17)` returns false and records `Conc17` as a dependency of `Outer17`, so
  # `Conc17` never joins `Outer17`'s ancestors; `Outer17.append_features(C17)` includes `Conc17` into `C17`, and
  # `Conc17`'s own `append_features` extends `C17` with `Conc17::ClassMethods`. The reader reaches the same module
  # through its `const_get` lookup along `Outer17`'s recorded includes, which agrees while `Outer17` has no
  # `ClassMethods` of its own (the next row is the case where it has one).
  it "reads a concern included into another concern that has no ClassMethods of its own" do
    source = "#{concern('Conc17')}module Outer17\n  extend ActiveSupport::Concern\n  include Conc17\nend\n" \
             "class C17\n  include Outer17\n  my_c :c17\nend\n"
    write_project(source, %w[C17.new.c17])
    expect(undefined_messages).to be_empty
  end

  # Issue #2992 — Concern also collects `Conc18` as a dependency of `C18` and extends `C18` with `Conc18::ClassMethods`
  # ahead of `Outer18::ClassMethods`, so the macro is `Conc18`'s.
  it "reads a dependency concern when the outer concern has its own ClassMethods" do
    outer = concern("Outer18", body: "n").sub("Concern\n", "Concern\n  include Conc18\n")
                                         .sub("my_c(*n) = n", "other = 1")
    write_project("class C18\n  include Outer18\n  my_c :c18\nend\n", %w[C18.new.c18],
                  extra_files: { "conc18.rb" => concern("Conc18"), "outer18.rb" => outer })
    expect(undefined_messages).to be_empty
  end

  # Known limit: here `Outer18b::ClassMethods#my_c` is nearer and defines nothing, so Ruby raises at `C18b.new.c18b`;
  # the reader looks for a definer anywhere on the singleton chain, not for the nearest `my_c` (#2901's rule).
  it "does not look past the nearer my_c of the outer concern's own ClassMethods" do
    outer = concern("Outer18b", body: "n").sub("Concern\n", "Concern\n  include Conc18b\n")
    write_project("class C18b\n  include Outer18b\n  my_c :c18b\nend\n", %w[C18b.new.c18b],
                  extra_files: { "conc18b.rb" => concern("Conc18b"), "outer18b.rb" => outer })
    expect(undefined_messages).to be_empty
  end

  # The `included` and `prepended` blocks run only for their own edge.
  def hook_concern(name, hook)
    "module #{name}\n  extend ActiveSupport::Concern\n  class_methods do\n    " \
      "def my_c(*n) = #{definer_body}\n  end\n  #{hook} do\n    my_c :#{name.downcase}\n  end\nend\n"
  end

  # A superclass whose `my_c` defines nothing, so a reporting row's class body runs in Ruby.
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

  # Issue #2992 — Ruby runs a concern's `included` / `prepended` block in every direct includer or prepender, a module
  # included, and a concern included into a concern in the outer concern's final includer, on that includer's edge.
  # Each concern is in its own file.
  describe "a hook block in a direct includer other than the receiver's class" do
    def block_concern(name, body: definer_body, **hooks)
      blocks = hooks.map { |hook, call| "  #{hook} do\n    #{call}\n  end\n" }.join
      "module #{name}\n  extend ActiveSupport::Concern\n  class_methods do\n    def my_c(*n) = #{body}\n  end\n" \
        "#{blocks}end\n"
    end

    def outer(name, edge, inner) = "module #{name}\n  extend ActiveSupport::Concern\n  #{edge} #{inner}\nend\n"

    it "reads an included block run in a module the class includes" do
      write_project("module Me\n  include Re\nend\nclass Ke\n  include Me\nend\n", %w[Ke.new.e],
                    extra_files: { "re.rb" => block_concern("Re", included: "my_c :e") })
      expect(undefined_messages).to be_empty
    end

    it "reads a prepended block run in a module the class includes" do
      write_project("module Mg\n  prepend Rg\nend\nclass Kg\n  include Mg\nend\n", %w[Kg.new.g],
                    extra_files: { "rg.rb" => block_concern("Rg", prepended: "my_c :g") })
      expect(undefined_messages).to be_empty
    end

    it "reads an included block run in a module the class prepends" do
      write_project("module Mh\n  include Rh\nend\nclass Kh\n  prepend Mh\nend\n", %w[Kh.new.h],
                    extra_files: { "rh.rb" => block_concern("Rh", included: "my_c :h") })
      expect(undefined_messages).to be_empty
    end

    it "does not read a module's prepended block for the included edge it was given" do
      write_project("module Mi\n  include Ri\nend\nclass Ki\n  include Mi\nend\n", %w[Ki.new.i],
                    extra_files: { "ri.rb" => block_concern("Ri", prepended: "my_c :i") })
      expect(undefined_messages).to eq(["undefined method `i' for Ki"])
    end

    it "reads a dependency concern's included block in the outer concern's includer" do
      write_project("class Kw\n  include Ow\nend\n", %w[Kw.new.w],
                    extra_files: { "cw.rb" => block_concern("Cw", included: "my_c :w"),
                                   "ow.rb" => outer("Ow", "include", "Cw") })
      expect(undefined_messages).to be_empty
    end

    it "reads a dependency of a dependency" do
      write_project("class Kv\n  include Ov\nend\n", %w[Kv.new.v],
                    extra_files: { "dv.rb" => block_concern("Dv", included: "my_c :v"),
                                   "cv.rb" => outer("Cv", "include", "Dv"), "ov.rb" => outer("Ov", "include", "Cv") })
      expect(undefined_messages).to be_empty
    end

    # The dependency runs on the final edge: `prepend Ox` prepends `Cx`, whatever edge `Ox` gave it.
    it "reads a dependency's prepended block for a class that prepends the outer concern" do
      write_project("class Kx\n  prepend Ox\nend\n", %w[Kx.new.x],
                    extra_files: { "cx.rb" => block_concern("Cx", prepended: "my_c :x"),
                                   "ox.rb" => outer("Ox", "include", "Cx") })
      expect(undefined_messages).to be_empty
    end

    # `Cy` is included after `Oy`'s `extend ActiveSupport::Concern`, so it is a dependency and `prepend Oy` prepends it.
    it "does not read a dependency's included block for a class that prepends the outer concern" do
      write_project("class Ky\n  prepend Oy\nend\n", %w[Ky.new.y],
                    extra_files: { "cy.rb" => block_concern("Cy", included: "my_c :y"),
                                   "oy.rb" => outer("Oy", "include", "Cy") })
      expect(undefined_messages).to eq(["undefined method `y' for Ky"])
    end

    # An `include` ahead of the `extend` (the next row) or in a reopening without it, which may load first, is an
    # ordinary one, whose block runs in the outer concern on its own edge.
    it "reads an included block of a concern included in a reopening of the outer concern" do
      reopened = "module Or\n  include Cr\nend\n"
      write_project("class Kr\n  prepend Or\nend\n", %w[Kr.new.r],
                    extra_files: { "cr.rb" => block_concern("Cr", included: "my_c :r"), "or_a.rb" => reopened,
                                   "or_b.rb" => "module Or\n  extend ActiveSupport::Concern\n  include Cr\nend\n" })
      expect(undefined_messages).to be_empty
    end

    it "reads an included block of a concern included ahead of the outer concern's extend" do
      oq = "module Oq\n  include Cq\n  extend ActiveSupport::Concern\nend\n"
      write_project("class Kq\n  prepend Oq\nend\n", %w[Kq.new.q],
                    extra_files: { "cq.rb" => block_concern("Cq", included: "my_c :q"), "oq.rb" => oq })
      expect(undefined_messages).to be_empty
    end

    # Guard: the reporting control for the dependency rows.
    it "does not open the includer when a dependency's macro defines nothing" do
      write_project("class Kt\n  include Ot\nend\n", %w[Kt.new.t],
                    extra_files: { "ct.rb" => block_concern("Ct", body: "n", included: "my_c :t"),
                                   "ot.rb" => outer("Ot", "include", "Ct") })
      expect(undefined_messages).to eq(["undefined method `t' for Kt"])
    end

    it "reads a macro call in a block that keeps self" do
      write_project("class Kb\n  include Rb\nend\n", %w[Kb.new.b],
                    extra_files: { "rb.rb" => block_concern("Rb", included: "[1].each { my_c :b }") })
      expect(undefined_messages).to be_empty
    end

    # The block runs on an instance, and only when that method is called.
    it "does not read a macro call in a define_method block" do
      write_project("class Kd\n  include Rd\nend\n", %w[Kd.new.d],
                    extra_files: { "rd.rb" => block_concern("Rd", included: "define_method(:later) { my_c :d }") })
      expect(undefined_messages).to eq(["undefined method `d' for Kd"])
    end

    # Issue #2992 — a lambda's, a proc's and `on_load`'s blocks run later, if at all, not on the includer as the block
    # runs.
    {
      "a lambda" => "@later = lambda { my_c :DEF }",
      "a Proc.new" => "@later = Proc.new { my_c :DEF }",
      "an on_load hook" => "ActiveSupport.on_load(:never_loaded) { my_c :DEF }"
    }.each_with_index do |(label, call), index|
      it "does not read a macro call in #{label} block" do
        name = "Dl#{index}"
        write_project("class K#{name}\n  include #{name}\nend\n", ["K#{name}.new.l#{index}"],
                      extra_files: { "dl#{index}.rb" => block_concern(name, included: call.sub("DEF", "l#{index}")) })
        expect(undefined_messages).to eq(["undefined method `l#{index}' for K#{name}"])
      end
    end

    # `after_save` here is the base class's own, which keeps its block and never runs it.
    it "does not read a macro call in a callback macro's block" do
      base = "class Bcb\n  def self.after_save(&) = nil\nend\n"
      write_project("#{base}class Kcb < Bcb\n  include Rcb\nend\n", %w[Kcb.new.cb],
                    extra_files: { "rcb.rb" => block_concern("Rcb", included: "after_save { my_c :cb }") })
      expect(undefined_messages).to eq(["undefined method `cb' for Kcb"])
    end

    {
      "collect" => "%i[DEF].collect { |n| my_c n }",
      "each_slice" => "%i[DEF].each_slice(1) { |ns| my_c(*ns) }",
      "reverse_each" => "%i[DEF].reverse_each { |n| my_c n }",
      "inject" => "%i[DEF].inject(0) { |acc, n| my_c n; acc }",
      "each.with_index" => "%i[DEF].each.with_index { |n, _| my_c n }",
      "find" => "%i[DEF].find { |n| my_c n; false }",
      "loop" => "loop do\n      my_c :DEF\n      break\n    end"
    }.each_with_index do |(label, call), index|
      it "reads a macro call in a #{label} block" do
        name = "Di#{index}"
        write_project("class K#{name}\n  include #{name}\nend\n", ["K#{name}.new.i#{index}"],
                      extra_files: { "di#{index}.rb" => block_concern(name, included: call.gsub("DEF", "i#{index}")) })
        expect(undefined_messages).to be_empty
      end
    end

    it "reads a macro call in an iterator block on a constant" do
      write_project("NAMES = %i[n1].freeze\nclass Kn\n  include Rn\nend\n", %w[Kn.new.n1],
                    extra_files: { "rn.rb" => block_concern("Rn", included: "NAMES.each { |n| my_c n }") })
      expect(undefined_messages).to be_empty
    end

    # `extend` runs `extended`, not `included`.
    it "does not read an included block for a class that only extends the concern" do
      write_project("class Kz\n  extend Rz\nend\n", %w[Kz.new.z],
                    extra_files: { "rz.rb" => block_concern("Rz", included: "my_c :z") })
      expect(undefined_messages).to eq(["undefined method `z' for Kz"])
    end

    # `ClassMethods` of a dependency is on the class object's ancestry, not its instances'. Each concern defines a
    # method of its own, as an empty concern opens its includer's instance side (#2094), and the dependency writes an
    # explicit `module ClassMethods`, since the walk also records a `class_methods` def on the concern itself.
    it "does not answer an instance-side call with a dependency's class method" do
      cc = "module Cc\n  extend ActiveSupport::Concern\n  def own = 1\n  " \
           "module ClassMethods\n    def build = 1\n  end\nend\n"
      oc = outer("Oc", "include", "Cc").sub("  include", "  def own = 1\n  include")
      write_project("class Kc\n  include Oc\nend\n", %w[Kc.new.build Kc.build.zork],
                    extra_files: { "cc.rb" => cc, "oc.rb" => oc })
      expect(undefined_messages).to eq(["undefined method `build' for Kc", "undefined method `zork' for 1"])
    end
  end

  describe "the ClassMethods a concern extends its includer with" do
    it "is not looked up in the namespace enclosing the concern" do
      source = "module Nj\n  module ClassMethods\n    def my_c(*n) = #{definer_body}\n  end\n  module Co\n    " \
               "extend ActiveSupport::Concern\n    def co = 1\n  end\nend\n" \
               "#{quiet_base('Bj')}class Cj < Bj\n  include Nj::Co\n  my_c :cj\nend\n"
      sig = "module Nj\n  module ClassMethods\n  end\n  module Co\n  end\nend\nclass Bj\nend\nclass Cj < Bj\nend\n"
      write_project(source, %w[Cj.new.cj], sig: sig)
      expect(undefined_messages).to eq(["undefined method `cj' for Cj"])
    end

    it "is the top-level ClassMethods when the concern has none" do
      source = "module ClassMethods\n  def my_c(*n) = #{definer_body}\nend\n" \
               "module Ct\n  extend ActiveSupport::Concern\n  def ct_own = 1\nend\n" \
               "class Ctc\n  include Ct\n  my_c :ct\nend\n"
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
