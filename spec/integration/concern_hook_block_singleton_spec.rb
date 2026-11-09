# frozen_string_literal: true

# Issue #3015 — two readings of a concern's `included` / `prepended` block, which Ruby runs in the includer's class
# body. A `def self.x` or `class << self` def there (or in a `class_methods` block, which Ruby runs on
# `Owner::ClassMethods`) is not the concern's own singleton method, and a `class << self` def there defines `x` on
# the includer's singleton class as #3005 reads a `def self.x` in the block.
#
# Every row's Ruby behaviour was witnessed on Ruby 4.0.5 with activesupport 8.1.4 loaded (`require
# "active_support/concern"`, left out here since the walk reads syntax only), each `lib/` file loaded in name order.
# Each concern sits in its own file, the includer in another and the calls in a third; `sig/` declares every class
# and module, empty, so RBS answers no call. A call `.zork` on a result reports the type the read gave it.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "concern hook block singleton defs (#3015)" do
  around do |example|
    Dir.mktmpdir("rigor-concern-hook-block-singleton-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # `files` maps `lib/` file names to their source; `calls` go in `lib/use.rb`; `members` maps a declared name to the
  # members its declaration lists. An includer whose declaration lists none, and whose singleton chain holds a module,
  # is open on its class side (#2438), so a row that expects a report on it gives it one.
  def write_project(files, calls, members: {})
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    declared = files.values.flat_map { |body| body.scan(/^\s*(class|module) ([\w:]+)( < \w+)?/) }.uniq
    sig = declared.map { |kind, name, sup| "#{kind} #{name}#{sup}\n#{members[name]}end\n" }.join
    File.write(File.join("sig", "types.rbs"), sig)
    files.each { |name, body| File.write(File.join("lib", name), body) }
    File.write(File.join("lib", "use.rb"), "def run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  def concern(name, body) = "module #{name}\n  extend ActiveSupport::Concern\n  def own = 1\n#{body}end\n"

  def block(hook, body) = "  #{hook} do\n#{body}  end\n"

  def singleton_class_body(body) = "    class << self\n#{body}    end\n"

  def includer(name, mixin, edge: "include") = "class #{name}\n  #{edge} #{mixin}\nend\n"

  let(:member) { "  def own: () -> Integer\n" }
  let(:made) { block("included", singleton_class_body("      def made = 4\n")) }

  describe "a class << self def in an included or prepended block" do
    it "answers the def on a direct includer of a single-file concern" do
      write_project({ "a_ce.rb" => concern("Ce", made), "k.rb" => includer("Ke", "Ce") }, ["Ke.made.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 4"])
    end

    it "answers the def of a reopening's block in another file" do
      write_project({ "a_ce.rb" => concern("Ce", ""), "b_reopen.rb" => "module Ce\n#{made}end\n",
                      "k.rb" => includer("Ke", "Ce") }, ["Ke.made.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 4"])
    end

    it "answers the def on a subclass of the includer" do
      write_project({ "a_ce.rb" => concern("Ce", made), "k.rb" => "#{includer('Ke', 'Ce')}class Se < Ke\nend\n" },
                    ["Se.made.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 4"])
    end

    it "answers the def of a prepended block on a prepender" do
      body = block("prepended", singleton_class_body("      def made = 6\n"))
      write_project({ "a_cp.rb" => concern("Cp", body), "k.rb" => includer("Kp", "Cp", edge: "prepend") },
                    ["Kp.made.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 6"])
    end

    it "still reports a class-side name no module or class provides" do
      write_project({ "a_ce.rb" => concern("Ce", made), "k.rb" => includer("Ke", "Ce") }, ["Ke.nope"],
                    members: { "Ke" => member })
      expect(undefined_messages).to eq(["undefined method `nope' for singleton(Ke)"])
    end

    # Ruby answers 4 for `Kb` (the block's `made` replaced the own one) and 1 for `Kc` (the own `def` replaced the
    # block's); the order of the `def` and the `include` is not in the tables, so the read withholds both ways.
    it "withholds an includer's own def self.x of the same name, written ahead of the include or after it" do
      write_project({ "a_ce.rb" => concern("Ce", made),
                      "k.rb" => "class Kb\n  def self.made = 1\n  include Ce\nend\n" \
                                "class Kc\n  include Ce\n  def self.made = 1\nend\n" },
                    ["Kb.made.zork", "Kc.made.zork"])
      expect(undefined_messages).to be_empty
    end

    # Ruby raises NoMethodError on both: `class << Xo` defines on `Xo`, and a `def self.x` in a `class << self`
    # body defines on the singleton class's own singleton class.
    it "reads no def of a class << other body, nor a def self.x in a class << self body" do
      body = block("included", "    class << Xo\n      def z = 1\n    end\n" \
                               "#{singleton_class_body("      def self.deep = 9\n")}")
      write_project({ "a_xo.rb" => "module Xo\nend\n", "b_cq.rb" => concern("Cq", body),
                      "k.rb" => includer("Kq", "Cq") }, ["Kq.z", "Kq.deep"], members: { "Kq" => member })
      expect(undefined_messages).to eq(["undefined method `deep' for singleton(Kq)",
                                        "undefined method `z' for singleton(Kq)"])
    end

    # Ruby raises NoMethodError on `Kv.made` (private method) and answers 7 to `Kv.send(:made)`. The module records no
    # visibility, so the body is read as opening the includer's class side: neither call reports.
    it "opens the includer's class side for a class << self body with a visibility call" do
      body = block("included", singleton_class_body("      private\n      def made = 7\n"))
      write_project({ "a_cv.rb" => concern("Cv", body), "k.rb" => includer("Kv", "Cv") },
                    ["Kv.send(:made).zork", "Kv.nope"], members: { "Kv" => member })
      expect(undefined_messages).to be_empty
    end
  end

  describe "a def self.x in a concern's included or class_methods block" do
    # Ruby answers 3 on `Kd`; `Cd.made` raises NoMethodError, but `Cd`'s own class side stays open (its
    # `extend ActiveSupport::Concern`), so the call on `Cd` is pinned as not answered, not as reported.
    it "still answers the includer, and no longer answers the def on the concern" do
      body = block("included", "    def self.made = 3\n") + block("class_methods", "    def self.cm = 5\n")
      write_project({ "a_cd.rb" => concern("Cd", body), "k.rb" => includer("Kd", "Cd") },
                    ["Kd.made.zork", "Cd.made.zork", "Cd.cm.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 3"])
    end

    # `Cd`'s class side is open (its `extend ActiveSupport::Concern`), so the call rows above cannot show the def is
    # no longer `Cd`'s; the one-file discovery tables do. Each `def` the block writes on `self`'s singleton class is
    # missing from `Cd`'s method, singleton-def and visibility tables, and kept on `Cd::<included>` (#3005); a class
    # the block opens keeps its own (Ruby answers 2 to `Cd::Inner.y`).
    it "leaves the block's singleton defs out of the concern's own tables" do
      inner = "    class Inner\n      def self.y = 2\n    end\n"
      body = block("included", "    def self.made = 3\n#{singleton_class_body("      def other = 4\n")}#{inner}") +
             block("class_methods", "    def self.cm = 5\n#{singleton_class_body("      def cm2 = 6\n")}")
      root = Prism.parse("#{concern('Cd', body)}module Cd\n  def self.mine = 7\nend\n").value
      scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
      singleton = %i[made other cm cm2 mine].select { |name| scope.discovered_methods["Cd"][name] == :singleton }
      nodes = %i[made other cm cm2 mine].select { |name| scope.singleton_def_for("Cd", name) }
      visible = scope.discovery.discovered_method_visibilities["Cd"].keys.grep(Array).map(&:last)
      kept = [scope.discovered_methods["Cd::Inner"], scope.singleton_def_for("Cd::Inner", :y)&.name]
      expect([singleton, nodes, visible, scope.discovered_methods["Cd::<included>"], kept])
        .to eq([%i[mine], %i[mine], %i[mine], { made: :instance, other: :instance }, [{ y: :singleton }, :y]])
    end

    # Ruby answers 8: `Cn`'s own `included` instance_evals the block on `Cn`, so the def is `Cn`'s own. The def in a
    # block is possible, so the read declines its type; `nope` shows the class side is still checked.
    it "keeps the def on a module whose included is its own DSL" do
      dsl = "module Cn\n  def self.included(base = nil, &blk) = blk ? instance_eval(&blk) : super\n" \
            "#{block('included', "    def self.made = 8\n")}end\n"
      write_project({ "a_cn.rb" => dsl }, ["Cn.made", "Cn.nope"], members: { "Cn" => member })
      expect(undefined_messages).to eq(["undefined method `nope' for singleton(Cn)"])
    end
  end
end
