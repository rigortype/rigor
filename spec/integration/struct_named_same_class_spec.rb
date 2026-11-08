# frozen_string_literal: true

# Issue #2979 — `K = Struct.new("Named", …)` binds `K` and `Struct::Named` to one class object
# (`K.equal?(Struct::Named)`), so a method defined under either name is the other's too: in the block, in a
# `class Struct::Named` reopening and in a `class K` reopening. `call.undefined-method` reads a struct-instance
# carrier as open, so these rows call through `self.` in a reopening and through `Struct::Named.new`, the shapes
# that reach a project class's method tables; `sig/` declares both names so the rule runs. Every row's Ruby
# behaviour was witnessed on Ruby 4.0.5.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "Struct.new with a class-name String: one class under two names (#2979)" do
  let(:defs) do
    <<~RUBY
      N = Struct.new("Named2", :n_url) do
        def own_url = 1
      end
      NK = Struct.new("NamedK", :k_url, keyword_init: true) do
        def own_k = 1
      end
      class N
        def from_k = 1
      end
    RUBY
  end

  let(:reopen) do
    <<~RUBY
      class Struct::Named2
        def extra_url = 1
        def go2 = [self.own_url, self.from_k]
      end
      class Struct::NamedK
        def extra_k = 1
        def go2 = self.own_k
      end
      class N
        def go3 = self.extra_url
      end
      class NK
        def go3 = self.extra_k
      end
      def run
        [Struct::Named2.new(1).own_url, Struct::Named2.new(1).from_k, Struct::NamedK.new(k_url: 1).own_k]
      end
    RUBY
  end

  let(:sig_source) { "class N\nend\nclass NK\nend\nclass Struct::Named2\nend\nclass Struct::NamedK\nend\n" }

  def diagnostics_of(files, sig = sig_source)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "types.rbs"), sig)
    files.each { |name, source| File.write(File.join("lib", name), source) }
    settings = { "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0 }
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(settings))
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]).diagnostics
  end

  def undefined_messages(files)
    diagnostics_of(files).select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  around do |example|
    Dir.mktmpdir("rigor-struct-named-same-class-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # File order is not load order: the reopening file sorts before and after the defining one, and the whole program
  # in one file is the third order.
  { "a reopening file sorted first" => "a.rb", "a reopening file sorted last" => "z.rb", "one file" => nil }
    .each do |where, reopen_file|
    it "reads a method under either name from the other, keyword_init: included, with #{where}" do
      files = reopen_file ? { "n.rb" => defs, reopen_file => reopen } : { "n.rb" => "#{defs}#{reopen}" }
      expect(undefined_messages(files)).to be_empty
    end
  end

  it "still reports a name neither name defines, on both names" do
    unknown = "class N\n  def u1 = self.zz1\nend\nclass Struct::Named2\n  def u2 = self.zz2\nend\n" \
              "def u3 = Struct::Named2.new(1).zz3\n"
    expect(undefined_messages({ "n.rb" => defs, "r.rb" => reopen, "u.rb" => unknown }))
      .to eq(["undefined method `zz1' for N", "undefined method `zz2' for Struct::Named2",
              "undefined method `zz3' for Struct::Named2"])
  end

  # A mixin edge under either name is the class's: on Ruby 4.0.5 every call below runs. Rows are instance calls
  # through `self.` that `call.undefined-method` reads, and `Reflection.project_method_defined` for the singleton
  # side, where the rule reports no project class object's missing method.
  describe "mixin edges under either name" do
    let(:mixins) do
      <<~RUBY
        N = Struct.new("Named2", :n_url)
        module Mx; def mx_x = 1; end
        module Px; def px_x = 1; end
        module Ey; def ey_x = 1; end
        module Ex; include Ey; def ex_x = 1; end
        module Fx; def fx_x = 1; end
        class Struct::Named2
          include Mx
          extend Ex
          def go4 = self.px_x
        end
        class N
          prepend Px
          extend Fx
          def go6 = self.mx_x
        end
      RUBY
    end

    it "reads an include on Struct::Named and a prepend on the constant from the other name" do
      expect(undefined_messages({ "n.rb" => mixins })).to be_empty
    end

    # `include(*MODS)` names no module, so the class may hold one the tables do not list; the chain of the other name
    # carries that mark too, and lists both names ahead of the mixins (`Struct::Named2.ancestors` begins
    # `[Struct::Named2, Zm]` on Ruby 4.0.5).
    it "carries an unrecordable include on Struct::Named onto the constant's chain" do
      source = "N = Struct.new(\"Named2\", :n_url)\nmodule Zm; def zz_x = 1; end\nMODS = [Zm]\n" \
               "class Struct::Named2\n  include(*MODS)\nend\nclass N\n  include Zm\nend\n"
      root = Prism.parse(source).value
      scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
      chain = Rigor::Scope::ResolutionChain.for(scope, "N", :instance, :methods)
      expect([chain.wildcard_mixin?, chain.entries.first(3).map(&:name)]).to eq([true, %w[N Struct::Named2 Zm]])
    end

    # The indexer folds an extended module's own `def`s into the extender's singleton table, so `Ey`, which `Ex`
    # includes, is the one only the chain's extend edge reaches.
    # The singleton side twin of the row above: an `extend` the tables cannot name, on `Struct::Named2`.
    it "carries an unrecordable extend on Struct::Named onto the constant's singleton chain" do
      source = "N = Struct.new(\"Named2\", :n_url)\nmodule Zm; def zz_x = 1; end\nMODS = [Zm]\n" \
               "class Struct::Named2\n  extend(*MODS)\nend\n"
      root = Prism.parse(source).value
      scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
      chain = Rigor::Scope::ResolutionChain.for(scope, "N", :singleton, :methods)
      expect([chain.wildcard_mixin?, chain.entries.first(2).map(&:name)]).to eq([true, %w[N Struct::Named2]])
    end

    it "reads an extend under either name on the other name's singleton side, for both walks" do
      root = Prism.parse(mixins).value
      scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
      answers = [%w[N ex_x], %w[N ey_x], %w[Struct::Named2 fx_x], %w[N zz_x]].flat_map do |class_name, method_name|
        %i[def discovered].map do |source|
          Rigor::Reflection.project_method_defined(class_name, method_name, kind: :singleton, source: source,
                                                                            scope: scope).to_s
        end
      end
      expect(answers).to eq(%w[yes yes yes yes yes yes no no])
    end
  end

  # A `def` under one name is a redefinition of the class's method under the other (Ruby keeps the last one
  # loaded), not an override, so no `def.override-*` rule compares the two. `Base`, which `Struct::Ov` includes, is
  # a true ancestor of both names, and `N#bp` reducing its visibility still reports.
  describe "the def.override-* rules across the two names" do
    let(:override_files) do
      {
        "n.rb" => <<~RUBY,
          module Base
            def bp = 0
          end
          N = Struct.new("Ov", :a) do
            def pub = 1
            private
            def secret = 1
          end
          class N
            def ret = 1
            def nar(v) = v
            private
            def pub2 = 1
            def bp = 1
          end
        RUBY
        "r.rb" => <<~RUBY
          class Struct::Ov
            include Base
            def secret = 2
            def ret = 2
            def nar(v) = v
            def pub2 = 2
            private
            def pub = 2
          end
        RUBY
      }
    end

    let(:override_sig) do
      <<~RBS
        module Base
        end
        class N
          def ret: () -> Integer
          def nar: (Integer) -> untyped
        end
        class Struct::Ov
          def ret: () -> Object
          def nar: (Numeric) -> untyped
        end
      RBS
    end

    it "reports no override between the two names in either direction, and still reports one from Base" do
      found = diagnostics_of(override_files, override_sig).select { |d| d.rule.start_with?("def.override-") }
      expect(found.map { |d| [File.basename(d.path), d.method_name, d.rule] })
        .to eq([["n.rb", "bp", "def.override-visibility-reduced"]])
    end
  end

  describe "the same-class entries the indexer records" do
    def same_class_names(source, name)
      root = Prism.parse(source).value
      scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
      Rigor::Scope::DiscoveryIndex.same_class_names(scope.discovered_parameter_envelopes[name])
    end

    it "binds the constant and Struct::Named to each other, blockless and nested included" do
      source = "N = Struct.new(\"Named\", :a)\nmodule Outer\n  NN = Struct.new(\"Named3\", :o) { def x = 1 }\nend\n"
      expect([same_class_names(source, "N"), same_class_names(source, "Struct::Named"),
              same_class_names(source, "Outer::NN"), same_class_names(source, "Struct::Named3")])
        .to eq([["Struct::Named"], ["N"], ["Struct::Named3"], ["Outer::NN"]])
    end

    # Ruby raises NameError for `Struct.new("lower", :a)` ("identifier lower needs to be constant"), so it names no
    # `Struct::` class; under `Class.new(Struct.new("Named", :a))` the constant is a subclass, not the class; and a
    # receiver other than `Struct` makes no `Struct::` class at all.
    # The entry names no member, so it does not declare a surface (`call.wrong-arity`'s project-class reading and
    # `SourceArity` read the declaring keys); the member entry beside it does.
    it "does not count the entry as declaring a surface" do
      root = Prism.parse("N = Struct.new(\"Named\", :a)\n").value
      scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
      bucket = scope.discovered_parameter_envelopes["Struct::Named"]
      expect(bucket.keys.to_h { |key| [key, Rigor::Scope::DiscoveryIndex.declares_surface?(key => bucket[key])] })
        .to eq([Rigor::Scope::DiscoveryIndex::ENVELOPE_SAME_CLASS_KIND, "N"] => false, %i[instance a] => true)
    end

    it "binds nothing for a String that is not a constant name, a wrapped factory, or another receiver" do
      source = "L = Struct.new(\"lower\", :a)\nW = Class.new(Struct.new(\"Wrapped\", :a))\n" \
               "O = Other.new(\"Oth\", :a)\n"
      expect(%w[L W Struct::Wrapped O Struct::Oth].map { |name| same_class_names(source, name) })
        .to eq([[], [], [], [], []])
    end
  end
end
