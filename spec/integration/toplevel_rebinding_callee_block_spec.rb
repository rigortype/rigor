# frozen_string_literal: true

# Issue #1817 — a top-level block handed to a project method that runs it with `module_eval(&blk)` (or
# `class_eval`, `instance_eval`, `instance_exec`, `class_exec`, `module_exec`) runs under another `self`, so a bare
# call inside it is not a top-level call and `call.unresolved-toplevel` must not report it. A callee that only
# `yield`s or calls the block keeps `main` as `self`, and the rule keeps reporting there.
#
# Every row is witnessed: Ruby evaluates it at the top level against the same callee file, and the rule must
# report exactly the rows Ruby raises NameError on.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "call.unresolved-toplevel inside a block a project callee rebinds (#1817)" do
  # The callees live in their own file, so the rule reads them through the cross-file project tables.
  let(:callees) do
    <<~RUBY
        class Target
          def helper = :target_helper
        end

        module Ext
          def self.helper = :ext_helper
          def self.me(&b) = module_eval(&b)
          def self.ce(&b) = class_eval(&b)
          def self.ie(&b) = instance_eval(&b)
          def self.ix(&b) = instance_exec(&b)
          def self.cx(&b) = class_exec(&b)
          def self.mx(&b) = module_exec(&b)
          def self.yields = yield
          def self.calls(&b) = b.call
          def self.guarded(&b) = (b.call if b)
        def self.anded(&b) = b && b.call
        def self.probe(&b) = (b.call if b.arity.zero? && !b.lambda? && b.parameters.empty? && !b.nil? && !!b)
        def self.trip(&b) = b === nil
        def self.idx(&b) = b[]
        def self.yld(&b) = b.yield

        def self.unl(&b)
          return unless b

          b.call
        end

        def self.unt(&b)
          until b; end
          b.call
        end

        def self.whl(&b)
          while b
            break
          end
          b.call
        end
          def self.other(&b) = Target.new.instance_exec(&b)

          def self.cond(flag, &b)
            if flag
              module_eval(&b)
            else
              b.call
            end
          end

          def self.anon(&) = module_eval(&)
        def self.bnd(&b) = module_eval(&binding.local_variable_get(:b))
          def self.fwd(...) = module_eval(...)

          def self.stored(&b)
            @b = b
            module_eval(&@b)
          end

          class << self
            define_method(:dm) { |&b| module_eval(&b) }
            alias_method :al, :ix
          end
        end

        class Base
          def self.dsl(&b) = instance_eval(&b)
          def self.helper = :base_helper
        end

        class Kid < Base
          def self.dsl = super
        end

        class Kid2 < Base
          def self.dsl = super()
        end

        # `super` hands the block to a core method that rebinds it: Struct.new and Data.define class_eval it.
      class Rec < Struct
        def self.helper = :rec_helper
        def self.new(*args) = super
      end

      class Dat < Data
        def self.helper = :dat_helper
        def self.define(*args) = super(*args)
      end

      def with_ext(&b) = Ext.module_eval(&b)
        def top_helper = :top_helper
        def top_yield = yield

        class Coll
          def helper = :coll_helper
          def each_item = yield
          def with_rebind(&b) = instance_exec(&b)
        end
    RUBY
  end

  # One row per line of the caller; each is a whole top-level statement.
  let(:rows) do
    [
      "Ext.me { helper }",
      "Ext.ce { helper }",
      "Ext.ie { helper }",
      "Ext.ix { helper }",
      "Ext.cx { helper }",
      "Ext.mx { helper }",
      "Ext.yields { helper }",
      "Ext.calls { helper }",
      "Ext.guarded { helper }",
      "Ext.anded { helper }",
      "Ext.probe { helper }",
      "Ext.trip { helper }",
      "Ext.idx { helper }",
      "Ext.yld { helper }",
      "Ext.unl { helper }",
      "Ext.unt { helper }",
      "Ext.whl { helper }",
      "Ext.other { helper }",
      "Ext.cond(true) { helper }",
      "Ext.send(:me) { helper }",
      "Ext.public_send(:yields) { helper }",
      "Ext.__send__(:ix) { helper }",
      "name = :me; Ext.send(name) { helper }",
      "Ext.me { [1].map { helper } }",
      "Ext.me { top_helper }",
      "Ext.anon { helper }",
      "Ext.bnd { helper }",
      "Ext.fwd { helper }",
      "Ext.stored { helper }",
      "Ext.dm { helper }",
      "Ext.al { helper }",
      "Ext.ix(&-> { helper })",
      "Ext.ix(&proc { helper })",
      "Ext.ix(&Proc.new { helper })",
      "top_yield { helper }",
      "Coll.new.each_item { helper }",
      "Coll.new.with_rebind { helper }",
      "Kid.dsl { helper }",
      "Kid2.dsl { helper }",
      "Rec.new(:a) { helper }",
      "Dat.define(:a) { helper }",
      "with_ext { helper }",
      "[1].each { helper }",
      "helper"
    ].freeze
  end

  let(:witness) do
    <<~RUBY
      require_relative "lib/ext"
      File.readlines(File.join(__dir__, "lib", "use.rb"), chomp: true).each_with_index do |row, index|
        next if index.zero?

        begin
          eval(row, TOPLEVEL_BINDING)
        rescue NameError => e
          raise unless e.name == :helper

          puts index + 1
        end
      end
    RUBY
  end
  let(:definer_callees) do
    <<~RUBY
      module Ext
        def self.helper = :ok
        def self.yields = yield
      end

      class Tgt
        def helper = :ok
      end

      Ext.define_singleton_method(:dsm) { |&b| module_eval(&b) }
      Ext.singleton_class.define_method(:sdm) { |&b| module_eval(&b) }
      Ext.singleton_class.send(:define_method, :snd) { |&b| module_eval(&b) }
      Ext.define_singleton_method(:dsp, proc { |&b| module_eval(&b) })
      Ext.singleton_class.alias_method :aka, :dsm
      Ext.singleton_class.send(:alias_method, :aka2, :dsm)

      module Cond
        def self.helper = :ok
        def self.define = yield
      end
      Cond.define_singleton_method(:define) { |&b| module_eval(&b) } if ENV["REBIND"]
    RUBY
  end
  let(:definer_uses) do
    ["Ext.dsm { helper }", "Ext.sdm { helper }", "Ext.snd { helper }", "Ext.dsp { helper }",
     "Ext.aka { helper }", "Ext.aka2 { helper }",
     "Cond.define { helper }", "Ext.define_singleton_method(:inner) { helper }; Ext.inner",
     "Tgt.define_method(:im) { helper }; Tgt.new.im", "Ext.yields { helper }", "helper", "undefined_ctl"]
  end

  def write_project
    FileUtils.mkdir_p("lib")
    File.write("lib/ext.rb", callees)
    File.write("lib/use.rb", ["require_relative \"ext\"", *rows].join("\n") << "\n")
  end

  def toplevel_lines(overrides = {})
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0, **overrides)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
      .diagnostics
      .select { |d| d.qualified_rule == "call.unresolved-toplevel" }
      .map { |d| [File.basename(d.path), d.line] }
  end

  def ruby_name_error_lines
    File.write("witness.rb", witness)
    out, err, status = RubyRun.capture("witness.rb")
    raise "witness failed: #{err}" unless status.success?

    out.split.map { |line| ["use.rb", Integer(line)] }
  end

  def line_of(row) = rows.index(row) + 2

  around do |example|
    Dir.mktmpdir("rigor-rebinding-callee-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "reports exactly the rows Ruby raises NameError on" do
    write_project
    expected = ruby_name_error_lines

    # Non-vacuity: Ruby rebinds most rows and leaves `self` as main on the plain-call ones.
    plain = ["Ext.yields { helper }", "Ext.calls { helper }", "Ext.guarded { helper }", "Ext.anded { helper }",
             "Ext.probe { helper }", "Ext.trip { helper }", "Ext.idx { helper }", "Ext.yld { helper }",
             "Ext.unl { helper }", "Ext.unt { helper }", "Ext.whl { helper }", "top_yield { helper }",
             "Coll.new.each_item { helper }", "Ext.public_send(:yields) { helper }", "[1].each { helper }", "helper"]
    expect(expected).to match_array(plain.map { |row| ["use.rb", line_of(row)] })
    expect(toplevel_lines).to match_array(expected)
  end

  it "stays silent on the issue's refine program, which Ruby runs" do
    FileUtils.mkdir_p("lib")
    File.write("lib/ext.rb", "module Ext\n  def self.define(&blk) = module_eval(&blk)\nend\n")
    File.write("lib/setup.rb", <<~RUBY)
      require_relative "ext"
      Ext.define do
        refine(String) { def center(a, b, c) = :top_block }
      end
    RUBY
    File.write("lib/a.rb", "require_relative \"setup\"\nusing Ext\np \"x\".center(1, 2, 3)\n")

    out, _err, status = RubyRun.capture("lib/a.rb")
    expect([out, status.success?]).to eq([":top_block\n", true])
    expect(toplevel_lines).to be_empty
  end

  it "declines by name: an unrelated callee of the same name that rebinds silences a yield-only one" do
    FileUtils.mkdir_p("lib")
    File.write("lib/ext.rb", "module Ext\n  def self.me(&b) = module_eval(&b)\nend\n")
    File.write("lib/plain.rb", "module Plain\n  def self.me = yield\nend\n")
    File.write("lib/use.rb", "Plain.me { helper }\nPlain.other { helper }\n")

    # Ruby raises NameError on both; the first is the accepted false negative of reading callees by name.
    expect(toplevel_lines).to eq([["use.rb", 2]])
  end

  it "declines when a sibling file or the other arm of an `if` gives the callee a body the table does not hold" do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", "module Ext\n  def self.define(&b) = module_eval(&b)\n  def self.helper = :ok\nend\n")
    File.write("lib/b.rb", "module Ext\n  def self.define = yield\nend\n")
    File.write("lib/c.rb", <<~RUBY)
      module Cond
        def self.helper = :ok

        if ENV["REBIND"]
          def self.define(&b) = module_eval(&b)
        else
          def self.define = yield
        end
      end
    RUBY
    File.write("lib/use.rb", "Ext.define { helper }\nCond.define { helper }\n")

    # File order is not load order, and either arm may run: Ruby runs the caller under one of them.
    runs = ->(*args) { RubyRun.capture(*args)[2].success? }
    expect(runs.call("-e", 'require "./lib/b"; require "./lib/a"; Ext.define { helper }')).to be(true)
    expect(runs.call("-e", 'require "./lib/a"; require "./lib/b"; Ext.define { helper }')).to be(false)
    expect(runs.call("-e", 'ENV["REBIND"] = "1"; require "./lib/c"; Cond.define { helper }')).to be(true)
    expect(toplevel_lines).to be_empty
  end

  it "declines on a callee a pre_eval: patch defines, whose body it does not read" do
    FileUtils.mkdir_p(%w[lib patches])
    File.write("patches/module.rb", "class Module\n  def pdefine(&b) = module_eval(&b)\nend\n")
    File.write("lib/use.rb",
               "module Ext\n  def self.helper = :ok\nend\nExt.pdefine { helper }\nExt.pother { helper }\n")

    out, _err, status = RubyRun.capture("-r", "./patches/module.rb", "-e",
                                        "module Ext; def self.helper = :ok; end; p Ext.pdefine { helper }")
    expect([out, status.success?]).to eq([":ok\n", true])
    expect(toplevel_lines("pre_eval" => ["patches/module.rb"])).to eq([["use.rb", 5]])
  end

  # A `def` written inside a block has a def-table slot but no named row; it must not stand in for a sibling's
  # unread body. A `module_function` row stands for both sides. Each pair is written in both file orders.
  it "declines on a sibling pair whatever else defines the name, in either file order" do
    rebind = "module Ext\n  def self.me(&b) = module_eval(&b)\n  def self.helper = :ok\nend\n"
    pairs = {
      "block def" => ["module Ext\n  def self.me = yield\nend\n",
                      "class Yk\n  [1].each do\n    def self.me = yield\n  end\nend\n"],
      "module_function" => ["module Ext\n  module_function\n\n  def me = yield\nend\n", nil]
    }
    pairs.each do |label, (yields, extra)|
      [%w[a b], %w[b a]].each do |first, second|
        FileUtils.rm_rf("lib")
        FileUtils.mkdir_p("lib")
        File.write("lib/#{first}.rb", rebind)
        File.write("lib/#{second}.rb", yields)
        File.write("lib/c.rb", extra) if extra
        File.write("lib/use.rb", "Ext.me { helper }\nundefined_ctl\n")
        expect(toplevel_lines).to eq([["use.rb", 2]]), "#{label}, #{first} then #{second}"
      end
    end
  end

  it "declines on a send whose String name is not valid in its encoding, and keeps the file's other reports" do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", "module Ext; def self.helper = :ok; end\nExt.send(\"\\xff\") { helper }\nundefined_ctl\n")

    expect(toplevel_lines).to eq([["a.rb", 3]])
  end

  # Its own project: a project `new` elsewhere would decline the `Proc.new` call's own block by name.
  it "reads a Proc.new literal passed with & as the block of the call it goes to" do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", "module Ext\n  def self.helper = :ok\n  def self.ix(&b) = instance_exec(&b)\nend\n")
    File.write("lib/use.rb", "Ext.ix(&Proc.new { helper })\nundefined_ctl\n")

    expect(toplevel_lines).to eq([["use.rb", 2]])
  end

  # Issue #2184 — the callee files load in `order`, then each line of lib/use.rb runs at the top level. Returns the
  # use.rb lines that raised NameError for `helper` or `undefined_ctl`; any other error fails the witness.
  def ruby_lines(order, env = {})
    File.write("witness.rb", <<~RUBY)
      #{env.map { |key, value| "ENV[#{key.inspect}] = #{value.inspect}" }.join("\n")}
      #{order.map { |file| "require_relative #{"lib/#{file}".inspect}" }.join("\n")}
      File.readlines(File.join(__dir__, "lib", "use.rb"), chomp: true).each_with_index do |row, index|
        eval(row, TOPLEVEL_BINDING)
      rescue NameError => e
        raise unless %i[helper undefined_ctl].include?(e.name)

        puts index + 1
      end
    RUBY
    out, err, status = RubyRun.capture("witness.rb")
    raise "witness failed: #{err}" unless status.success?

    out.split.map { |line| ["use.rb", Integer(line)] }
  end

  def write_files(files)
    FileUtils.rm_rf("lib")
    FileUtils.mkdir_p("lib")
    files.each { |name, source| File.write("lib/#{name}", source) }
  end

  def use_lines(uses, *picked) = picked.map { |row| ["use.rb", uses.index(row) + 1] }

  it "declines on a callee only define_singleton_method or define_method names, and in such a call's block" do
    uses = definer_uses
    write_files(
      "ext.rb" => definer_callees,
      "use.rb" => "#{uses.join("\n")}\n"
    )

    # The statement that may not run decides `Cond.define`: Ruby raises without it and runs the block with it.
    controls = use_lines(uses, "Ext.yields { helper }", "helper", "undefined_ctl")
    expect(ruby_lines(%w[ext.rb])).to match_array(controls + use_lines(uses, "Cond.define { helper }"))
    expect(ruby_lines(%w[ext.rb], "REBIND" => "1")).to match_array(controls)
    # ext.rb:13 is `module_eval` in the proc `dsp` is defined from, a block passed as a value, which #2186 covers.
    expect(toplevel_lines).to match_array(controls + [["ext.rb", 13]])
  end

  # Ruby reaches a method_missing only for a name the receiver lacks: `Array#each` and `Integer#times` are RBS
  # methods, so a project method_missing, here one that passes its block on through `super`, cannot run their blocks.
  it "keeps reporting in a block whose callee resolves on its receiver, whatever method_missing the project has" do
    uses = ["[1, 2].each { |x| helper }", "2.times { helper }", "Ext.anything { helper }", "undefined_ctl"]
    write_files(
      "ext.rb" => <<~RUBY,
        class Config
          def method_missing(name, *args) = name == :foo ? 1 : super
        end

        module Ext
          def self.helper = :ok
          def self.method_missing(*, &b) = module_eval(&b)
        end
      RUBY
      "use.rb" => "#{uses.join("\n")}\n"
    )

    expected = use_lines(uses, "[1, 2].each { |x| helper }", "2.times { helper }", "undefined_ctl")
    expect(ruby_lines(%w[ext.rb])).to match_array(expected)
    expect(toplevel_lines).to match_array(expected)
  end

  it "declines on any callee when a project method_missing may hand its block on" do
    uses = ["Ext.anything { helper }", "helper", "undefined_ctl"]
    rebinds = "module Ext\n  def self.helper = :ok\n  def self.method_missing(*, &b) = module_eval(&b)\nend\n"
    write_files("ext.rb" => rebinds, "use.rb" => "#{uses.join("\n")}\n")
    expected = use_lines(uses, "helper", "undefined_ctl")
    expect(ruby_lines(%w[ext.rb])).to match_array(expected)
    expect(toplevel_lines).to match_array(expected)

    # Positive control: a method_missing that only yields runs the block under main.
    write_files("ext.rb" => rebinds.sub("module_eval(&b)", "yield"), "use.rb" => "#{uses.join("\n")}\n")
    expected = use_lines(uses, *uses)
    expect(ruby_lines(%w[ext.rb])).to match_array(expected)
    expect(toplevel_lines).to match_array(expected)
  end

  # A `def` inside a block or a method body names no slot of its own: when a sibling's `def` holds the table slot,
  # the rule still must not read that sibling as the only body. File order is not load order. Pool mode folds the
  # same rows.
  it "declines on a callee a def inside a block or a method body defines, whichever sibling holds the slot" do
    uses = ["Ext.me { helper }", "Ext.setup; Ext.later { helper }", "Ext.other { helper }", "undefined_ctl"]
    write_files(
      "a.rb" => <<~RUBY,
        class Ext
          def self.helper = :ok

          [1].each do
            def self.me(&b) = module_eval(&b)
          end

          def self.setup
            def self.later(&b) = module_eval(&b)
          end
        end
      RUBY
      "b.rb" => "class Ext\n  def self.me = yield\n  def self.other = yield\nend\n",
      "use.rb" => "#{uses.join("\n")}\n"
    )

    controls = use_lines(uses, "Ext.other { helper }", "undefined_ctl")
    expect(ruby_lines(%w[b.rb a.rb])).to match_array(controls)
    expect(ruby_lines(%w[a.rb b.rb])).to match_array(controls + use_lines(uses, "Ext.me { helper }"))
    expect(toplevel_lines).to match_array(controls)
    expect(toplevel_lines("workers" => 2)).to match_array(controls)
  end

  # The conservative reading: a top-level `define_method` defines a private method of Object, which Ruby may call on
  # main or on any other object, so the rule cannot prove the block runs under main and declines.
  it "declines in a top-level define_method block even where Ruby calls the method on main" do
    write_files("use.rb" => "define_method(:tdm) { helper }\nsend(:tdm)\nundefined_ctl\n")

    expect(ruby_lines([])).to eq([["use.rb", 2], ["use.rb", 3]])
    expect(toplevel_lines).to eq([["use.rb", 3]])
  end

  # A block call chained on, or passed into, another block call: the enclosing rebinding block starts before the
  # outer call's block, whatever order the file's walk meets the two calls in.
  it "declines in a rebinding block nested in another block call's receiver or arguments" do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", <<~RUBY)
      module Ext
        def self.helper = :ok
        def self.me(&b) = module_eval(&b)
      end
      Ext.me { helper }.then { |x| x }
      [Ext.me { helper }].each { |x| x }
      p(Ext.me { helper }) { nil }
      y = Ext.me { helper }.to_s.tap { nil }
      undefined_ctl
    RUBY

    expect(toplevel_lines).to eq([["a.rb", 9]])
  end
end
