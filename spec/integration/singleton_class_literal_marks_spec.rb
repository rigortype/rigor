# frozen_string_literal: true

# Issue #1906 — a `singleton_class.alias_method` / `define_method` / `remove_method` that spells every name it
# rewrites as a literal makes only those singleton names opaque, so `call.wrong-arity` keeps checking the class's
# other singleton methods. A computed name, or any other surface call on `singleton_class`, still leaves the whole
# singleton side unreadable. Each expectation is Ruby 4.0.5's answer: a reported call raises `ArgumentError`.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "singleton_class calls with literal names (#1906)", type: :runner do
  def arity_rows(files)
    analyze(files: files).diagnostics.select { |d| d.rule == "call.wrong-arity" }
                         .map { |d| [File.basename(d.path.to_s), d.line, d.message] }.sort
  end

  def arity(klass, name) = "wrong number of arguments to `#{name}' on #{klass} (given 2, expected 1)"

  let(:indirect_rewrites) do
    {
      "foo.rb" => <<~RUBY,
        class Foo; def self.find(id) = id; end
        class D1; def self.own(a) = a; def self.other(a, b) = a; end
        class D2; def self.own(a) = a; def self.other(a, b) = a; end
        class D4; def self.own(a) = a; def self.other(a, b) = a; end
        class D9; def self.own(a) = a; def self.other(a, b) = a; end
        class A1; def self.own(a) = a; end
        class C5; def self.own(a) = a; def self.other(a, b) = a; end
      RUBY
      "patches.rb" => <<~RUBY,
        module Patches
          def self.apply!
            Foo.singleton_class.alias_method :orig_find, :find
            Foo.singleton_class.define_method(:find) { |id, opts = {}| orig_find(id) }
          end
        end
        class Setup1
          def self.setup
            D1.singleton_class.alias_method :own, :other
          end
          def self.setup2 = D2.singleton_class.alias_method(:own, :other)
          def self.setup3 = A1.singleton_class.attr_reader(:own)
        end
        def setup4 = D4.singleton_class.alias_method(:own, :other)
        module X9
          def self.included(base)
            D9.singleton_class.alias_method :own, :other
          end
        end
        C5.singleton_class.alias_method :own, :other if Foo.respond_to?(:find)
      RUBY
      "app.rb" => <<~RUBY
        Patches.apply!
        Setup1.setup
        Setup1.setup2
        Setup1.setup3
        setup4
        class Host; include X9; end
        p Foo.find(1, { cache: true })
        p D1.own(1, 2), D2.own(1, 2), D4.own(1, 2), D9.own(1, 2), C5.own(1, 2)
        p A1.own
      RUBY
    }
  end
  let(:inherited_rewrites) do
    <<~RUBY
      class B2
        def self.own(a) = a
        def self.other(a, b) = a
      end
      class D2 < B2
        singleton_class.alias_method :own, :other
      end
      module Mx
        def own(a) = a
        def other(a, b) = a
      end
      class E1
        extend Mx
        singleton_class.alias_method :own, :other
      end
      class E2
        extend Mx
        singleton_class.define_method(:own) { |*a| a }
      end
      module S1
        extend self
        def own(a) = a
        def other(a, b) = a
        singleton_class.alias_method :own, :other
      end
      module F1
        module_function
        def own(a) = a
        def other(a, b) = a
        singleton_class.alias_method :own, :other
      end
      D2.own(1, 2)
      E1.own(1, 2)
      E2.own(1, 2)
      S1.own(1, 2)
      F1.own(1, 2)
    RUBY
  end

  # `D.own(1, 2)`, `M.own(1, 2)` and `Q.keep(1, 2)` raise; `D.o2(1)` and `M.o3(1)` return 1, and `Q.own(1, 2)` runs
  # `other`'s body. `define_method`'s second argument is the body, not a name, so it need not be a literal.
  it "keeps checking a singleton method the call does not rewrite" do
    expect(arity_rows("app.rb" => <<~RUBY)).to eq(
      class D
        def self.own(a) = a
        singleton_class.alias_method :o2, :own
      end
      class M
        def self.own(a) = a
        singleton_class.alias_method "o3", "own"
      end
      class Q
        def self.own(a) = a
        def self.other(a, b) = a
        def self.keep(a) = a
        singleton_class.define_method(:own, singleton_class.instance_method(:other))
      end
      D.own(1, 2)
      D.o2(1)
      M.own(1, 2)
      M.o3(1)
      Q.own(1, 2)
      Q.keep(1, 2)
    RUBY
      [["app.rb", 15, arity("D", "own")], ["app.rb", 17, arity("M", "own")], ["app.rb", 20, arity("Q", "keep")]]
    )
  end

  # Ruby 4.0.5 answers `1`, `[1, 2]`, a `NoMethodError` and `1`: the rewritten name runs another body or none.
  it "declines on the names the call rewrites" do
    expect(arity_rows("app.rb" => <<~RUBY)).to eq([])
      class G
        def self.own(a) = a
        def self.other(a, b) = a
        singleton_class.alias_method :own, :other
      end
      class H
        def self.own(a) = a
        singleton_class.define_method(:own) { |*a| a }
      end
      class J
        def self.own(a) = a
        singleton_class.remove_method :own
      end
      class M
        def self.three(a) = a
        def self.other(a, b) = a
        singleton_class.alias_method "three", "other"
      end
      G.own(1, 2)
      H.own(1, 2)
      J.own(1, 2)
      M.three(1, 2)
    RUBY
  end

  # Each of these already declined before #1906. Ruby 4.0.5 raises `ArgumentError` on every call but `K2.own(1, 2)`,
  # which the computed `define_method` answers with `[1, 2]`; the walk cannot tell which.
  it "keeps the singleton side unreadable for a computed name" do
    expect(arity_rows("app.rb" => <<~RUBY)).to eq([])
      class K
        def self.own(a) = a
        name = :o2
        singleton_class.alias_method name, :own
      end
      class K2
        def self.own(a) = a
        sym = :own
        singleton_class.define_method(sym) { |*a| a }
      end
      class K3
        def self.own(a) = a
        args = %i[o2 own]
        singleton_class.alias_method(*args)
      end
      K.own(1, 2)
      K2.own(1, 2)
      K3.own(1, 2)
    RUBY
  end

  # A guard: both declined before #1906 and no change here reaches them. Ruby 4.0.5 raises `ArgumentError` on both.
  it "keeps the singleton side unreadable for another surface call" do
    expect(arity_rows("app.rb" => <<~RUBY)).to eq([])
      class L
        def self.own(a) = a
        singleton_class.class_eval { def x = 1 }
      end
      class L2
        def self.own(a) = a
        singleton_class.send(:alias_method, :o2, :own)
      end
      L.own(1, 2)
      L2.own(1, 2)
    RUBY
  end

  # The rewritten name's old definer is not the class's own `def self.own`: an inherited singleton method, an
  # extended module's, an `extend self` or `module_function` module's own. Ruby 4.0.5 runs the rewritten body (`1`,
  # `1`, `[1, 2]`, `1`, `1`), so only the name's opaque envelope keeps the check off.
  it "declines a rewritten name whose old definer is inherited or extended" do
    expect(arity_rows("app.rb" => inherited_rewrites)).to eq([])
  end

  # A literal naming call that is not a direct statement — in a method body or a hook outside the constant's class,
  # or behind a condition — may run on a receiver or at a time no mark places, so the whole singleton side stays
  # unreadable. Ruby 4.0.5 prints `1` for every call but `A1.own`, which the reader answers with `nil`. Before #1906 the
  # `alias_method` and `define_method` calls tainted the side too, while the `attr_reader` call was neither marked nor
  # tainted and `A1.own` was reported.
  it "keeps the singleton side unreadable for a literal naming call that is not a direct statement" do
    expect(arity_rows(indirect_rewrites)).to eq([])
  end

  # The class body and the `singleton_class` call live in different files, reopening the class or calling on the
  # constant. Ruby 4.0.5 runs `D.own` through the alias of `keep`, so it answers; `E.own` has no new body and raises,
  # as do `D.keep` and `E.keep`.
  it "reads a singleton_class call in another file" do
    files = {
      "d.rb" => "class D\n  def self.own(a) = a\n  def self.keep(a) = a\nend\n" \
                "class E\n  def self.own(a) = a\n  def self.keep(a) = a\nend\n",
      "rewrite.rb" => "D.singleton_class.alias_method :own, :keep\n" \
                      "class E\n  singleton_class.define_method(:o9) { |*a| a }\nend\n",
      "app.rb" => "D.own(1, 2)\nD.keep(1, 2)\nE.own(1, 2)\nE.keep(1, 2)\n"
    }
    expect(arity_rows(files)).to eq(
      [["app.rb", 2, arity("D", "keep")], ["app.rb", 3, arity("E", "own")], ["app.rb", 4, arity("E", "keep")]]
    )
  end

  # The file that rewrites `D`'s singleton side declares nothing, so neither the reader's class edge nor the
  # class-declaration diff reaches the reader when it changes which name it rewrites.
  describe "an incremental recheck" do
    around do |example|
      Dir.mktmpdir("rigor-singleton-class-literal-marks-") { |dir| Dir.chdir(dir) { example.run } }
    end

    let(:paths) { %w[lib/d.rb lib/rewrite.rb] }

    def write(relative, contents)
      FileUtils.mkdir_p(File.dirname(relative))
      File.write(relative, contents)
    end

    def configuration
      Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
    end

    def rows(diagnostics)
      diagnostics.select { |d| d.rule == "call.wrong-arity" }.map { |d| [d.path, d.line] }.sort
    end

    def incremental_rows
      root = File.join(Dir.pwd, ".rigor", "cache")
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths,
                                                        cache_store: Rigor::Cache::Store.new(root: root))
      diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
      [rows(diagnostics), warm]
    end

    def cold_rows
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
      rows(guarded_run(runner, paths).diagnostics)
    end

    it "re-checks the reader when the rewritten name moves away from and back to its call" do
      write("lib/d.rb", "class D\n  def self.own(a) = a\n  def self.keep(a) = a\nend\nD.own(1, 2)\n")
      write("lib/rewrite.rb", "D.singleton_class.remove_method :own\n")
      expect(incremental_rows).to eq([[], false])

      write("lib/rewrite.rb", "D.singleton_class.remove_method :keep\n")
      expect(incremental_rows).to eq([[["lib/d.rb", 5]], true])
      expect(cold_rows).to eq([["lib/d.rb", 5]])

      write("lib/rewrite.rb", "D.singleton_class.alias_method :own, :keep\n")
      expect(incremental_rows).to eq([[], true])
      expect(cold_rows).to eq([])
    end

    # The edit turns the call on the constant into a reopening, so `D` stays in the file's declaration set and the
    # reader's class edge, recorded before the file declared `D`, does not name it: the before-edit names fire.
    it "re-checks the reader when a call on the constant becomes a reopening that rewrites the name" do
      write("lib/d.rb", "class D\n  def self.own(a) = a\n  def self.keep(a) = a\nend\nD.own(1, 2)\n")
      write("lib/rewrite.rb", "D.singleton_class.remove_method :keep\n")
      expect(incremental_rows).to eq([[["lib/d.rb", 5]], false])

      write("lib/rewrite.rb", "class D\n  singleton_class.define_method(:own) { |*a| a }\nend\n")
      expect(incremental_rows).to eq([[], true])
      expect(cold_rows).to eq([])
    end

    # A computed name leaves `D`'s singleton side unpositioned and records no envelope entry; once the name is a
    # literal the side reads again, and only the unpositioned side recorded before the edit names `D`.
    it "re-checks the reader when a computed name becomes a literal one" do
      write("lib/d.rb", "class D\n  def self.own(a) = a\n  def self.keep(a) = a\nend\nD.own(1, 2)\n")
      write("lib/rewrite.rb", "name = :o9\nD.singleton_class.alias_method name, :keep\n")
      expect(incremental_rows).to eq([[], false])

      write("lib/rewrite.rb", "D.singleton_class.alias_method :o9, :keep\n")
      expect(incremental_rows).to eq([[["lib/d.rb", 5]], true])
      expect(cold_rows).to eq([["lib/d.rb", 5]])
    end

    # The key fires only for a constant whose singleton names or side the file rewrote: `ActiveRecord::Base.include`
    # puts the constant in the singleton-source set but records neither, so it re-checks no `*::Base` reader.
    it "keys only the constants whose singleton names or side the file rewrote" do
      write("lib/rewrite.rb", "ActiveRecord::Base.include(Mo)\nD.singleton_class.alias_method :o9, :keep\n" \
                               "E.singleton_class.class_eval { }\n")
      index = Rigor::Inference::ScopeIndexer.discovered_project_index_incremental(["lib/rewrite.rb"], seed_bundles: {})
      bundle = index.fetch(:bundles).fetch("lib/rewrite.rb")
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths, cache_store: nil)

      expect(bundle[:singleton_class_source_names]).to include("ActiveRecord::Base")
      expect(session.send(:singleton_rewritten_constants, bundle).sort).to eq(%w[D E])
    end
  end
end
