# frozen_string_literal: true

# Issue #1592 — a class's singleton resolution chain holds the modules its direct mixins' hooks extend it with, and
# those hooks live in the mixin's file, which a class-side call has no other edge to. Editing that file, or adding a
# file that reopens the mixin or declares the module its hook names, must re-check the call: `--incremental` must
# serve what a cold run reports. `sig/` declares every class and module, empty, so RBS answers no call.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"
require "rigor/protection/discovery_seed"

RSpec.describe "incremental edges for a hook-extended singleton module (#1592)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-singleton-hook-extend-edge-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [d.path, d.line, d.message] }
  end

  def cold_rows
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    rows(guarded_run(runner, %w[lib]).diagnostics).sort
  end

  def incremental_rows(paths)
    root = File.join(Dir.pwd, ".rigor", "cache")
    snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
    session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths,
                                                      cache_store: Rigor::Cache::Store.new(root: root))
    diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
    [rows(diagnostics).sort, warm]
  end

  # Writes `files`, runs once, rewrites `lib/near.rb` to `after`, and expects the warm run to equal a cold one.
  def expect_toggle(files, before:, after:, first:, second:)
    write("sig/types.rbs", sig_source)
    files.merge("lib/near.rb" => before).each { |path, source| write(path, source) }
    paths = (files.keys + ["lib/near.rb"]).sort
    expect(incremental_rows(paths)).to eq([first, false])
    expect(cold_rows).to eq(first)

    write("lib/near.rb", after)
    expect(incremental_rows(paths)).to eq([second, true])
    expect(cold_rows).to eq(second)
  end

  def sig_source = "module Ct\nend\nmodule Dt\nend\nmodule X\nend\nclass Base\nend\nclass Kt < Base\nend\n"

  let(:files) do
    { "lib/base.rb" => "class Base\n  def self.bar = 1\nend\nmodule X\n  def bar = \"X\"\nend\n",
      "lib/kt.rb" => "class Kt < Base\n  include Ct\nend\n",
      "lib/use.rb" => "Kt.bar.zork\n" }
  end

  def reported(type) = [["lib/use.rb", 1, "undefined method `zork' for #{type}"]]

  def concern(body) = "module Ct\n  extend ActiveSupport::Concern\n  def own = 1\n#{body}end\n"

  it "re-checks the call when the concern's file gains a class_methods def" do
    expect_toggle(files, before: concern(""), after: concern("  class_methods do\n    def bar = :cm\n  end\n"),
                         first: reported(1), second: reported(":cm"))
  end

  it "re-checks the call when the concern's file loses its class_methods def" do
    expect_toggle(files, before: concern("  class_methods do\n    def bar = :cm\n  end\n"), after: concern(""),
                         first: reported(":cm"), second: reported(1))
  end

  it "re-checks the call when the concern's file gains an included block's extend" do
    expect_toggle(files, before: concern(""), after: concern("  included do\n    extend X\n  end\n"),
                         first: reported(1), second: reported('"X"'))
  end

  # The reopening repeats `extend ActiveSupport::Concern`: the walk reads a `class_methods` block only in a body that
  # runs it.
  it "re-checks the call when a file reopening the concern adds a class_methods def" do
    reopened = files.merge("lib/ct.rb" => concern(""))
    expect_toggle(reopened, before: "",
                            after: "module Ct\n  extend ActiveSupport::Concern\n  class_methods do\n    " \
                                   "def bar = :cm\n  end\nend\n",
                            first: reported(1), second: reported(":cm"))
  end

  # Until a file declares it, the hook's `ClassMethods` is a module the project does not know, which may define any
  # name, so the read declines.
  it "re-checks the call when a new file declares the module the hook names" do
    hook = { "lib/ct.rb" => "module Ct\n  def self.included(base) = base.extend(ClassMethods)\nend\n" }
    expect_toggle(files.merge(hook), before: "",
                                     after: "module Ct\n  module ClassMethods\n    def bar = :cm\n  end\nend\n",
                                     first: [], second: reported(":cm"))
  end

  # Issue #2992 — `Ct` includes the concern `Dt`, a dependency whose `ClassMethods` reaches `Kt`; `Dt` is declared
  # only in `near.rb`, which no entry of `Kt`'s chain names until it has a `class_methods` block. Guards, with the
  # next row: the edges the chain and the typing read already file re-check the call, and no line of the dependency
  # read is needed for it.
  it "re-checks the call when a dependency concern's file gains a class_methods def" do
    dependency = "module Dt\n  extend ActiveSupport::Concern\n  def dt_own = 1\n%send\n"
    outer = { "lib/ct.rb" => concern("  include Dt\n") }
    expect_toggle(files.merge(outer), before: format(dependency, ""),
                                      after: format(dependency, "  class_methods do\n    def bar = :cm\n  end\n"),
                                      first: reported(1), second: reported(":cm"))
  end

  it "re-checks the call when a file reopening a dependency concern adds a class_methods def" do
    dependency = "module Dt\n  extend ActiveSupport::Concern\n  def dt_own = 1\nend\n"
    reopened = files.merge("lib/ct.rb" => concern("  include Dt\n"), "lib/dt.rb" => dependency)
    expect_toggle(reopened, before: "",
                            after: "module Dt\n  extend ActiveSupport::Concern\n  class_methods do\n    " \
                                   "def bar = :cm\n  end\nend\n",
                            first: reported(1), second: reported(":cm"))
  end

  # `Dt`'s hook extends with another spelling than `ClassMethods`, which only the dependency's own edges name.
  it "re-checks the call when a dependency concern's file gains an included block's extend" do
    dependency = "module Dt\n  extend ActiveSupport::Concern\n  def dt_own = 1\n%send\n"
    outer = { "lib/ct.rb" => concern("  include Dt\n") }
    expect_toggle(files.merge(outer), before: format(dependency, ""),
                                      after: format(dependency, "  included do\n    extend X\n  end\n"),
                                      first: reported(1), second: reported('"X"'))
  end

  # `Dt` turns into a concern, and with it into a dependency of `Ct`, whose `ClassMethods` then reaches `Kt`.
  it "re-checks the call when an included module's file makes it a concern" do
    dependency = "module Dt\n%s  def dt_own = 1\n  module ClassMethods\n    def bar = :cm\n  end\nend\n"
    outer = { "lib/ct.rb" => concern("  include Dt\n  class_methods do\n    def other = 1\n  end\n") }
    expect_toggle(files.merge(outer), before: format(dependency, ""),
                                      after: format(dependency, "  extend ActiveSupport::Concern\n"),
                                      first: reported(1), second: reported(":cm"))
  end

  # Issue #2997 — a reopening's `class_methods` block is read whether or not the reopening repeats the `extend`;
  # whether `Ct` is a concern, and so whether `Kt` draws on `Ct::ClassMethods`, is the declaring file's.
  describe "a reopening's class_methods block when the declaring file changes" do
    let(:reopened) { files.merge("lib/ct.rb" => "module Ct\n  class_methods do\n    def bar = :cm\n  end\nend\n") }
    let(:plain) { "module Ct\n  def own = 1\nend\n" }

    it "re-checks the call when the declaring file gains the extend" do
      expect_toggle(reopened, before: plain, after: concern(""), first: reported(1), second: reported(":cm"))
    end

    it "re-checks the call when the declaring file loses the extend" do
      expect_toggle(reopened, before: concern(""), after: plain, first: reported(":cm"), second: reported(1))
    end
  end

  # Issue #3005 — a reopening's `included` block is read whether or not the reopening repeats the `extend`, under a
  # hook that counts only while some file declares the module a concern; a `def self.x` in it defines on the includer.
  # Ruby runs the block only for an `include` that runs after it, so the includer and the call load last here.
  describe "a reopening's included block without the extend" do
    let(:late) do
      { "lib/base.rb" => files["lib/base.rb"], "lib/x_kt.rb" => files["lib/kt.rb"], "lib/y_use.rb" => "Kt.bar.zork\n" }
    end

    def late_reported(type) = [["lib/y_use.rb", 1, "undefined method `zork' for #{type}"]]

    it "re-checks the call when the reopening file appears with an extend" do
      expect_toggle(late.merge("lib/ct.rb" => concern("")),
                    before: "", after: "module Ct\n  included do\n    extend X\n  end\nend\n",
                    first: late_reported(1), second: late_reported('"X"'))
    end

    it "re-checks the call when the reopening file appears with a def self.x" do
      expect_toggle(late.merge("lib/ct.rb" => concern("")),
                    before: "", after: "module Ct\n  included do\n    def self.bar = :blk\n  end\nend\n",
                    first: late_reported(1), second: late_reported(":blk"))
    end

    it "re-checks the call when the declaring file loses the extend" do
      reopened = late.merge("lib/r_ct.rb" => "module Ct\n  included do\n    extend X\n  end\nend\n")
      expect_toggle(reopened, before: concern(""), after: "module Ct\n  def own = 1\nend\n",
                              first: late_reported('"X"'), second: late_reported(1))
    end
  end

  # Issue #2997 — a hook defined by `class << self` or `define_singleton_method` is read as `def self.included` is.
  describe "a hook whose spelling switches" do
    let(:dsm) { "module Ct\n  define_singleton_method(:included) { |base| base.extend(X) }\nend\n" }

    it "re-checks the call when class << self; def included gives way to define_singleton_method" do
      singleton = "module Ct\n  class << self\n    def included(base) = nil\n  end\nend\n"
      expect_toggle(files, before: singleton, after: dsm, first: reported(1), second: reported('"X"'))
    end

    it "re-checks the call when the define_singleton_method's name becomes computed" do
      computed = "module Ct\n  name = :included\n  define_singleton_method(name) { |base| base.extend(X) }\nend\n"
      expect_toggle(files, before: dsm, after: computed, first: reported('"X"'), second: [])
    end
  end

  # Ruby keeps whichever definition loaded last, so with two the read declines.
  describe "a second file that redefines the hook" do
    let(:hooked) { files.merge("lib/ct.rb" => "module Ct\n  def self.included(base) = base.extend(X)\nend\n") }
    let(:redefinition) { "module Ct\n  def self.included(base) = nil\nend\n" }

    it "re-checks the call when the redefinition appears" do
      expect_toggle(hooked, before: "", after: redefinition, first: reported('"X"'), second: [])
    end

    it "re-checks the call when the redefinition goes" do
      expect_toggle(hooked, before: redefinition, after: "", first: [], second: reported('"X"'))
    end
  end

  # The edges a singleton read files for the includer's direct mixin, which the chain's own entries do not name:
  # the mixin's declaring file, and the negative `mark:` and `class:` edges on its last segment.
  it "files the mixin's class edge and its mark: and class: edges on a singleton read" do
    write("sig/types.rbs", sig_source)
    hooked = files.merge("lib/ct.rb" => concern("  class_methods do\n    def bar = :cm\n  end\n"))
    hooked.each { |path, source| write(path, source) }
    tables = Rigor::Protection::DiscoverySeed.discovery_tables(Dir["lib/*.rb"].map { |path| File.expand_path(path) })
    scope = Rigor::Scope.empty.then { |base| base.with_discovery(base.discovery.with(**tables)) }
    record = Rigor::Analysis::DependencyRecorder.record_for(File.expand_path("lib/use.rb")) do
      Rigor::Scope::ResolutionChain.for(scope, "Kt", :singleton, :methods).search(scope) { nil }
    end
    expect(record.sources.map { |path| File.basename(path) }).to include("ct.rb")
    expect(record.missing).to include("mark:Ct", "class:Ct")
  end

  # Issue #2998 — a reopening in another file prepends `X` to `Kt`'s singleton class, ahead of its own `def self.bar`
  # (an `extend X` would sit behind it); the warm run must follow the prepend line in and out of that file.
  describe "a singleton prepend in a file reopening the class" do
    let(:plain) { files.merge("lib/kt.rb" => "class Kt < Base\n  def self.bar = 1\nend\n") }
    let(:prepended) { "class Kt < Base\n  class << self\n    prepend X\n  end\nend\n" }

    it "re-checks the call when the reopening gains the prepend" do
      expect_toggle(plain, before: "class Kt < Base\nend\n", after: prepended,
                           first: reported(1), second: reported('"X"'))
    end

    it "re-checks the call when the reopening loses the prepend" do
      expect_toggle(plain, before: prepended, after: "class Kt < Base\nend\n",
                           first: reported('"X"'), second: reported(1))
    end

    # A NEW file that reopens `Kt` to prepend `X` re-checks a read that stopped at `Kt`'s own def, on `Kt` and on its
    # subclass `St`, in both spellings; removing the file again re-checks it back.
    {
      "class << self" => "class Kt < Base\n  class << self\n    prepend X\n  end\nend\n",
      "singleton_class.prepend" => "class Kt < Base\n  singleton_class.prepend X\nend\n"
    }.each do |label, source|
      it "re-checks the call when a new file adds a #{label} prepend, and when it goes" do
        write("sig/types.rbs", "#{sig_source}class St < Kt\nend\n")
        files = plain.merge("lib/st.rb" => "class St < Kt\nend\n", "lib/use.rb" => "Kt.bar.zork\nSt.bar.zork\n")
        files.each { |path, body| write(path, body) }
        paths = %w[lib]
        both = ->(type) { [1, 2].map { |line| ["lib/use.rb", line, "undefined method `zork' for #{type}"] } }
        expect(incremental_rows(paths)).to eq([both.call(1), false])

        write("lib/near.rb", source)
        expect(incremental_rows(paths)).to eq([both.call('"X"'), true])
        expect(cold_rows).to eq(both.call('"X"'))

        File.delete("lib/near.rb")
        expect(incremental_rows(paths)).to eq([both.call(1), true])
        expect(cold_rows).to eq(both.call(1))
      end
    end
    # `Kt` already prepends `Y`, which answers ahead of `Kt`'s own entry; a NEW file prepending `X` makes two prepends
    # from two files, whose order is load order, so the cold read declines and the warm one must too. Guard: the
    # settle verdict's filing past the answer already names `Kt`.
    it "re-checks a call a prepended module answers when a new file adds a second prepend" do
      prepend_y = "module Y\n  def bar = \"Y\"\nend\n" \
                  "class Kt < Base\n  def self.bar = 1\n  class << self\n    prepend Y\n  end\nend\n"
      write("sig/types.rbs", "#{sig_source}module Y\nend\n")
      files.merge("lib/kt.rb" => prepend_y).each { |path, body| write(path, body) }
      expect(incremental_rows(%w[lib])).to eq([reported('"Y"'), false])

      write("lib/near.rb", "class Kt < Base\n  class << self\n    prepend X\n  end\nend\n")
      expect(incremental_rows(%w[lib])).to eq([[], true])
      expect(cold_rows).to eq([])
    end

    # The NEW file prepends to the subclass, whose entry the read of `St.bar` passes before `Kt`'s own def answers.
    it "re-checks a subclass's call when a new file prepends to the subclass" do
      write("sig/types.rbs", "#{sig_source}class St < Kt\nend\n")
      files = plain.merge("lib/st.rb" => "class St < Kt\nend\n", "lib/use.rb" => "Kt.bar.zork\nSt.bar.zork\n")
      files.each { |path, body| write(path, body) }
      row = ->(line, type) { ["lib/use.rb", line, "undefined method `zork' for #{type}"] }
      expect(incremental_rows(%w[lib])).to eq([[row.call(1, 1), row.call(2, 1)], false])

      # `Kt.bar` goes unreported once `near.rb` reopens `St`, on the base engine too; the row compares the warm run with
      # the cold one.
      write("lib/near.rb", "class St < Kt\n  class << self\n    prepend X\n  end\nend\n")
      expect(incremental_rows(%w[lib])).to eq([[row.call(2, '"X"')], true])
      expect(cold_rows).to eq([row.call(2, '"X"')])
    end
  end
end
