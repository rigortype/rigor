# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# ADR-24 (amended for #1567, #1568, #1570, #1571) — the read-level witness for `Scope::ResolutionChain`: each
# fixture runs under the suite's own Ruby in a child process, and what Ruby resolves is compared with what the
# chain's readers answer over the discovery index `rigor check` builds for the same file.
#
# - `methods:` — `C.instance_method(:foo)` (or `C.method(:foo)` for a `.`-query) and its `super_method` chain:
#   the owner and `source_location` line of every definer Ruby reaches, against `Scope#user_def_through_ancestors`
#   (or `#singleton_def_through_ancestors`) for the first, and the chain's project definers for the rest.
# - `ancestors:` — `C.ancestors` restricted to what the fixture declares, against the chain's project entries.
# - `constants:` — the first ancestor after `C` that defines the constant, against the constant ladder's
#   ancestor rung (`Reflection.ancestor_constant_scopes`).
#
# Singleton-side owners are not compared: the extends fold copies an extended module's `def`s into the
# extender's singleton table, so the chain names the extender where Ruby names the module. The `def` line —
# which body runs — is compared instead.
#
# The tables do not record how a body interleaves its `include` and `prepend` statements, nor `class << self;
# prepend`; `ResolutionChain` documents both. The fixtures that show them pin the chain's answer next to Ruby's.
RESOLUTION_CHAIN_WITNESS_FIXTURES = {
  "include through an included module beats the superclass (#1567)" => {
    source: <<~RUBY,
      class Base
        def foo = 1
      end

      module M
        def foo = "m"
      end

      module A
        include M
      end

      class C < Base
        include A
      end
    RUBY
    methods: ["C#foo"], ancestors: ["C"]
  },
  "a prepended module's public def beats the class's private one (#1568)" => {
    source: <<~RUBY,
      module P
        def foo = :p
      end

      class C
        prepend P

        private

        def foo = :c
      end
    RUBY
    methods: ["C#foo"], ancestors: ["C"]
  },
  "an include of a module the superclass already includes is a no-op (#1570)" => {
    source: <<~RUBY,
      module M
        def foo(x) = x
      end

      class Base
        include M

        def foo = 1
      end

      class C < Base
        include M
      end
    RUBY
    # Skipped in Ruby's order and not in the retro world (`[C, M, Base, M]`): the worlds disagree, and the
    # reader keeps master's `M#foo` — #1570's false positive is not fixed while the tables cannot say which ran.
    methods: ["C#foo"], ancestors: ["C"], master: ["C#foo"]
  },
  "an include of a module the superclass prepends is a no-op" => {
    source: <<~RUBY,
      module P
        def foo = [:p, *super]
      end

      class Base
        prepend P

        def foo = [:base]
      end

      class C < Base
        include P

        def foo = [:c, *super]
      end
    RUBY
    methods: ["C#foo"], ancestors: ["C"]
  },
  "a prepend of a module the superclass includes is not skipped" => {
    source: <<~RUBY,
      module W
        def foo = [:w, *(defined?(super) ? super : [])]
      end

      class Base
        include W

        def foo = [:base, *super]
      end

      class C < Base
        prepend W

        def foo = [:c, *super]
      end
    RUBY
    methods: ["C#foo"], ancestors: ["C"]
  },
  "prepend then include of the same module" => {
    source: <<~RUBY,
      module M
        def foo = [:m, *(defined?(super) ? super : [])]
      end

      class C
        prepend M
        include M

        def foo = [:c, *super]
      end
    RUBY
    methods: ["C#foo"], ancestors: ["C"]
  },
  "include M, N searches M first; a later include N searches N first" => {
    source: <<~RUBY,
      module M
        def foo = :m
      end

      module N
        def foo = :n
      end

      class OneStatement
        include M, N
      end

      class TwoStatements
        include M
        include N
      end
    RUBY
    methods: ["OneStatement#foo", "TwoStatements#foo"], ancestors: %w[OneStatement TwoStatements]
  },
  "a diamond keeps the shared module after both sides" => {
    source: <<~RUBY,
      module D
        def foo = [:d]
      end

      module L
        include D

        def foo = [:l, *super]
      end

      module R
        include D

        def foo = [:r, *super]
      end

      class C
        include L
        include R
      end
    RUBY
    methods: ["C#foo"], ancestors: ["C"]
  },
  "an already-present include moves the insertion point past it" => {
    source: <<~RUBY,
      module M
        def foo = [:m]
      end

      module Z
        include M

        def foo = [:z, *super]
      end

      class MThenZ
        include M
        include Z
      end

      class ZThenM
        include Z
        include M
      end
    RUBY
    # `include Z; include M` skips `M` (Z already carries it); the retro world, where `Z` was reopened to include
    # `M` after the class included it, puts `M` first.
    methods: ["MThenZ#foo", "ZThenM#foo"], ancestors: %w[MThenZ ZThenM], master: ["ZThenM#foo"]
  },
  "a module's own prepends come before it in its includer" => {
    source: <<~RUBY,
      module N
        def foo = [:n, *super]
      end

      module PP
        prepend N

        def foo = [:pp]
      end

      class C
        include PP
      end
    RUBY
    methods: ["C#foo"], ancestors: ["C"]
  },
  "an include added to a module after a class included it reaches the class" => {
    source: <<~RUBY,
      module R
        def foo = [:r]
      end

      module Q
        def foo = [:q, *super]
      end

      class C
        include Q
      end

      module Q
        include R
      end
    RUBY
    methods: ["C#foo"], ancestors: ["C"]
  },
  "a superclass reopened to include a module its subclass already included" => {
    source: <<~RUBY,
      module M
        def foo = "m"
      end

      class Base
        def foo = 1
      end

      class C < Base
        include M
      end

      class Base
        include M
      end
    RUBY
    # Ruby ran `C`'s include first, so it keeps both copies: `[C, M, Base, M]`, the retro world. The final
    # tables alone give `[C, Base, M]` and `Base#foo`; the reader keeps master's answer, which is Ruby's here.
    methods: ["C#foo"], ancestors: ["C"], world: :retro, master: ["C#foo"]
  },
  "a module reopened to include a module its includer already included" => {
    source: <<~RUBY,
      module M
        def foo = "m"
      end

      module N
        def foo = 1
      end

      class C
        include M
        include N
      end

      module M
        include N
      end
    RUBY
    methods: ["C#foo"], ancestors: ["C"], world: :retro, master: ["C#foo"]
  },
  "a conditional include in the superclass (run with it unset)" => {
    source: <<~RUBY,
      module M
        def foo = "m"
      end

      class Base
        include M if ENV["RIGOR_WITNESS_UNSET"]

        def foo = 1
      end

      class C < Base
        include M
      end
    RUBY
    # The tables read the conditional include as certain (ADR-119 adds `possible`), which makes `C`'s own
    # include a skip; unset, Ruby runs `[C, M, Base]`. The reader keeps master's answer rather than `Base#foo`.
    methods: ["C#foo"], world: :retro, master: ["C#foo"], super: false
  },
  "two skips of which neither world reaches the definer Ruby calls" => {
    source: <<~RUBY,
      module Deep
        def foo = 1
      end

      module D
        def foo = "d"
      end

      module A
        include Deep
      end

      module N
      end

      class Base
        include N
        include A
      end

      class C < Base
        include D
        include A
      end

      module N
        include D
      end
    RUBY
    # `C` ran its includes while `N` was still empty, so `D` was new to it and `A` a skip: Ruby's ancestors are
    # `[C, D, Base, A, Deep, N, D]` and `D#foo` runs. The final tables make BOTH of `C`'s includes skips, and
    # the two worlds a one-skip-at-a-time logic would compare — every skip made, or none — both put `Deep`
    # first (`[C, Base, A, Deep, N, D]` and `[C, A, Deep, D, Base, ...]`). Agreement of two worlds proves
    # nothing once a chain holds two skips, so `settle` hands the decision to master's order, which reaches
    # `D` first here.
    methods: ["C#foo"], master: ["C#foo"], third: ["C#foo"], super: false
  },
  "a class that only extends, as the superclass of a singleton chain with a skip" => {
    source: <<~RUBY,
      module Deep
        def foo = "deep"
      end

      module E0
        include Deep
      end

      module E1
        include Deep
      end

      class Base
        extend E0
      end

      class C < Base
        def self.foo = 1
      end

      class D < C
        extend E1
      end
    RUBY
    # `Base` only `extend`s, which the `:methods` predicate does not admit as a class, so its singleton chain
    # was cut short and `E1`'s skip of `Deep` went uncounted. Ruby runs `C.foo`.
    methods: ["D.foo"]
  },
  "extend self puts the module's own instance chain after its singleton" => {
    source: <<~RUBY,
      module N
        def build = :n
      end

      module M
        include N
        extend self

        def label = :m
      end
    RUBY
    # `M.build` is `N#build` in Ruby. The extends fold copies only `M`'s own `def`s into `M`'s singleton table;
    # `N` answers as its own entry of the singleton chain (`[#<Class:M>, M, N]`), where the superclass-only walk
    # the chain replaced answered nothing.
    methods: ["M.label", "M.build"], ancestors: ["M.singleton"]
  },
  "a class method from a module an extended module includes beats the superclass's (#1567, singleton side)" => {
    source: <<~RUBY,
      class Base
        def self.foo = 1
      end

      module M
        def foo = "m"
      end

      module A
        include M
      end

      class C < Base
        extend A
      end
    RUBY
    methods: ["C.foo"], ancestors: ["C.singleton"]
  },
  "a constant read in a method body through an included module's include (#1571, the review's probe)" => {
    source: <<~RUBY,
      class Base
        X = 1
      end

      module M
        X = "m"
      end

      module A
        include M
      end

      class C < Base
        include A
        def bar = X
      end
    RUBY
    constants: ["C::X"], ancestors: ["C"], flavor: :constants
  },
  "extend and class << self; include take the later statement first" => {
    source: <<~RUBY,
      module E1
        def build = :e1
      end

      module E2
        def build = :e2
      end

      class ExtendFirst
        extend E1

        class << self
          include E2
        end
      end

      class IncludeFirst
        class << self
          include E2
        end

        extend E1
      end

      class Base
        def self.build = :base
      end

      class ExtendsOverBase < Base
        extend E1
      end

      class InheritsBase < Base
      end
    RUBY
    methods: ["ExtendFirst.build", "IncludeFirst.build", "ExtendsOverBase.build", "InheritsBase.build"],
    ancestors: %w[ExtendFirst.singleton IncludeFirst.singleton ExtendsOverBase.singleton]
  },
  "a constant through an included module beats the superclass's (#1571)" => {
    source: <<~RUBY,
      class Base
        X = 1
      end

      module M
        X = "m"
      end

      module A
        include M
      end

      class C < Base
        include A
      end
    RUBY
    # `Base`, `A` and `M` declare no method, so only the constant ladder's `:constants` flavor admits them as
    # project classes.
    constants: ["C::X"], ancestors: ["C"], flavor: :constants
  }
}.freeze

# The child process's half: what Ruby resolves for every query of one fixture, as JSON.
RESOLUTION_CHAIN_WITNESS_PROBE = <<~'RUBY'
  require "json"
  fixture, queries = ARGV[0], JSON.parse(ARGV[1])
  $stdout = File.open(File::NULL, "w")
  load fixture
  $stdout = STDOUT
  declared = ->(mod) do
    mod = mod.attached_object if mod.singleton_class?
    name = mod.name
    !name.nil? && Object.const_source_location(name)&.first == fixture
  end
  label = ->(mod) { mod.singleton_class? ? [mod.attached_object.name, "singleton"] : [mod.name, "instance"] }
  out = {}
  queries.fetch("methods", []).each do |query|
    singleton = query.include?(".")
    class_name, method_name = query.split(singleton ? "." : "#")
    klass = Object.const_get(class_name)
    method = singleton ? klass.method(method_name) : klass.instance_method(method_name)
    definers = []
    while method
      owner = method.owner
      definers << [label.(owner).first, method.source_location&.last] if declared.(owner)
      method = method.super_method
    end
    out[query] = definers
  end
  queries.fetch("ancestors", []).each do |query|
    class_name, side = query.split(".")
    klass = Object.const_get(class_name)
    list = side == "singleton" ? klass.singleton_class.ancestors : klass.ancestors
    out["ancestors:#{query}"] = list.select { |mod| declared.(mod) }.map { |mod| label.(mod) }
  end
  queries.fetch("constants", []).each do |query|
    class_name, constant = query.split("::")
    klass = Object.const_get(class_name)
    owner = klass.ancestors.drop(1).find { |mod| mod.const_defined?(constant, false) && declared.(mod) }
    out["constants:#{query}"] = owner&.name
  end
  puts JSON.generate(out)
RUBY

RSpec.describe "Scope::ResolutionChain against Ruby's own resolution" do
  def ruby_answers(path, fixture)
    queries = fixture.slice(:methods, :ancestors, :constants).transform_keys(&:to_s)
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(RbConfig.ruby, "-e", RESOLUTION_CHAIN_WITNESS_PROBE, path, JSON.generate(queries))
    end
    raise "fixture probe failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def rigor_scope(source)
    root = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
  end

  # Every project definer of `method_name` along one world of `class_name`'s chain, in order — what Ruby's
  # `super_method` walk meets when that world is the one that ran.
  def chain_of(scope, class_name, side = :instance, flavor = :methods)
    Rigor::Scope::ResolutionChain.for(scope, class_name, side, flavor)
  end

  def rigor_instance_definers(scope, class_name, method_name, world = :skip)
    chain = world == :retro ? ResolutionChainRetro.build(scope, class_name) : chain_of(scope, class_name)
    chain.entries.filter_map do |entry|
      found = !entry.external? && scope.user_def_for(entry.name, method_name)
      [entry.name, found.location.start_line] if found
    end
  end

  # The reader itself: the first definer where the chain's two worlds agree, master's where they do not.
  def rigor_definer(scope, class_name, method_name)
    node, owner = scope.user_def_through_ancestors(class_name, method_name)
    [owner, node&.location&.start_line]
  end

  # What the breadth-first walk the chain replaced answered — the reader's answer where the worlds disagree.
  def master_definer(scope, class_name, method_name)
    Rigor::Scope::ResolutionChain::MasterOrder.definer_sequence(scope, class_name).each do |name|
      node = scope.user_def_for(name, method_name)
      return [name, node.location.start_line] if node
    end
    nil
  end

  # The singleton side's lookups read the class objects' own entries, whose positions both worlds share, so they
  # have no contested answer to decline.
  def rigor_agreed_singleton_line(scope, class_name, method_name)
    node, = scope.singleton_def_through_ancestors(class_name, method_name)
    node&.location&.start_line
  end

  def rigor_ancestors(scope, query, declared, flavor, world)
    class_name, side = query.split(".")
    side = side == "singleton" ? :singleton : :instance
    chain = if world == :retro
              ResolutionChainRetro.build(scope, class_name, side, flavor)
            else
              chain_of(scope, class_name, side, flavor)
            end
    chain.entries.reject(&:external?).map { |entry| [entry.name, entry.side.to_s] }
         .select { |pair| declared.include?(pair.first) }
  end

  # The constant ladder's ancestor rung: the first ancestor, in the order it searches, that owns the constant.
  def rigor_constant_owner(scope, query)
    class_name, constant = query.split("::")
    Rigor::Reflection.send(:ancestor_constant_scopes, class_name, scope)
                     .find { |candidate| scope.in_source_constants.key?("#{candidate}::#{constant}") }
  end

  def declared_names(source)
    source.scan(/^\s*(?:class|module)\s+([A-Z]\w*)/).flatten
  end

  # A query the fixture lists under `master:` is one the two worlds of the chain answer differently. The
  # reader keeps the answer of the walk it replaced there (ADR-24 § "Amendment 2026-09-28"), and Ruby's own
  # answer is one of the two worlds' — which one depends on the order the bodies ran, which the tables lack.
  def expect_agreed(actual, ruby_answer, candidates, master_answer)
    if master_answer
      expect(actual).to eq(master_answer)
      expect(candidates).to include(ruby_answer)
    else
      expect(actual).to eq(ruby_answer)
    end
  end

  RESOLUTION_CHAIN_WITNESS_FIXTURES.each do |title, fixture|
    describe title do
      let(:answers) do
        Dir.mktmpdir("rigor-chain-witness-") do |dir|
          path = File.join(dir, "fixture.rb")
          File.write(path, fixture[:source])
          ruby_answers(path, fixture)
        end
      end
      let(:scope) { rigor_scope(fixture[:source]) }
      let(:world) { fixture.fetch(:world, :skip) }

      fixture.fetch(:methods, []).each do |query|
        suffix = fixture.fetch(:master, []).include?(query) ? ", or master's where the worlds disagree" : ""
        if query.include?(".")
          it "resolves #{query} to the body Ruby runs" do
            class_name, method_name = query.split(".")
            ruby_line = answers.fetch(query).first&.last
            expect_agreed(rigor_agreed_singleton_line(scope, class_name, method_name.to_sym), ruby_line,
                          [ruby_line], nil)
          end
        else
          it "resolves #{query} to the definer Ruby calls#{suffix}" do
            class_name, method_name = query.split("#")
            actual = rigor_definer(scope, class_name, method_name.to_sym)
            next expect(actual).to eq(answers.fetch(query).first) unless fixture.fetch(:master, []).include?(query)

            candidates = %i[skip retro].map do |each_world|
              rigor_instance_definers(scope, class_name, method_name.to_sym, each_world).first
            end
            if fixture.fetch(:third, []).include?(query)
              # Neither world holds Ruby's definer; only the ≥2-skips rule to master's order reaches it.
              expect(candidates).not_to include(answers.fetch(query).first)
              expect(actual).to eq(answers.fetch(query).first)
              next
            end

            expect_agreed(actual, answers.fetch(query).first, candidates,
                          master_definer(scope, class_name, method_name.to_sym))
          end

          next if fixture[:super] == false

          it "walks #{query}'s super chain through Ruby's definers in the #{fixture.fetch(:world, :skip)} world" do
            class_name, method_name = query.split("#")
            expect(rigor_instance_definers(scope, class_name, method_name.to_sym, world)).to eq(answers.fetch(query))
          end
        end
      end

      fixture.fetch(:ancestors, []).each do |query|
        it "orders #{query}'s declared ancestors as Ruby does in the #{fixture.fetch(:world, :skip)} world" do
          declared = declared_names(fixture[:source])
          expect(rigor_ancestors(scope, query, declared, fixture.fetch(:flavor, :methods), world))
            .to eq(answers.fetch("ancestors:#{query}"))
        end
      end

      fixture.fetch(:constants, []).each do |query|
        it "finds #{query} in the ancestor Ruby reads it from" do
          expect(rigor_constant_owner(scope, query)).to eq(answers.fetch("constants:#{query}"))
        end
      end
    end
  end

  # The two gaps `ResolutionChain` documents, pinned beside Ruby's answer. Neither changes a first definer.
  describe "what the tables cannot record" do
    it "misses the trailing copy of a module included before it is prepended ([M, C, M] in Ruby)" do
      source = <<~RUBY
        module M
          def foo = [:m, *(defined?(super) ? super : [])]
        end

        class C
          include M
          prepend M

          def foo = [:c, *super]
        end
      RUBY
      Dir.mktmpdir("rigor-chain-witness-") do |dir|
        path = File.join(dir, "fixture.rb")
        File.write(path, source)
        ruby = ruby_answers(path, { methods: ["C#foo"] }).fetch("C#foo")
        rigor = rigor_instance_definers(rigor_scope(source), "C", :foo)
        expect(ruby.map(&:first)).to eq(%w[M C M])
        expect(rigor.map(&:first)).to eq(%w[M C])
        expect(rigor.first).to eq(ruby.first)
      end
    end

    # The same gap, reached through a module's own includes (`ResolutionChain` header): the trailing copy of a
    # module the class prepends AND reaches by an include, where the include is on the class or, in the second
    # shape, the prepend carries the module. The first definer is the same either way.
    def expect_missing_trailing_copy(source, class_name, ruby_owners, rigor_owners)
      Dir.mktmpdir("rigor-chain-witness-") do |dir|
        path = File.join(dir, "fixture.rb")
        File.write(path, source)
        ruby = ruby_answers(path, { methods: ["#{class_name}#foo"] }).fetch("#{class_name}#foo")
        rigor = rigor_instance_definers(rigor_scope(source), class_name, :foo)
        expect([ruby.map(&:first), rigor.map(&:first)]).to eq([ruby_owners, rigor_owners])
        expect(rigor.first).to eq(ruby.first)
      end
    end

    it "misses the trailing copy of a module the class prepends and an included module includes" do
      expect_missing_trailing_copy(<<~RUBY, "C2", %w[M C2 M], %w[M C2])
        module M
          def foo = [:m, *(defined?(super) ? super : [])]
        end

        module A
          include M
        end

        class C2
          include A
          prepend M

          def foo = [:c2, *super]
        end
      RUBY
    end

    it "misses the trailing copy of a module the class includes and a prepended module includes" do
      expect_missing_trailing_copy(<<~RUBY, "C3", %w[P M C3 M], %w[P M C3])
        module M
          def foo = [:m, *(defined?(super) ? super : [])]
        end

        module P
          include M

          def foo = [:p, *super]
        end

        class C3
          include M
          prepend P

          def foo = [:c3, *super]
        end
      RUBY
    end

    # A prepend's result depends on whether the module included its own modules before or after the prepend
    # ran. `A` included `M` after `D` prepended it, and `M` was already in `C`'s chain, so Ruby reads `D`'s
    # constant `X` from `C`; the final tables read alone put `M` ahead of `D`. The prepend of `A` forks, so
    # every reader settles to master's order.
    it "settles to master where a prepended module's later include is already in the superclass chain" do
      source = <<~RUBY
        module A; end
        module M; X = "m"; end
        class C; include M; X = 1; end
        class D < C; prepend A; end
        module A; include M; end
      RUBY
      Dir.mktmpdir("rigor-chain-witness-") do |dir|
        path = File.join(dir, "fixture.rb")
        File.write(path, source)
        expect(ruby_answers(path, { constants: ["D::X"] }).fetch("constants:D::X")).to eq("C")
        scope = rigor_scope(source)
        chain = chain_of(scope, "D", :instance, :constants)
        expect(chain.skip_count).to be >= 1
        expect(chain.settle(scope, :answer) { raise "no retro world for a prepend fork" }).to eq(:master)
        expect(chain.instance_variable_get(:@retro)).to be_nil
      end
    end

    # A module that both prepends and includes the same module is recorded as a plain prepend. Ruby's `C`
    # is `[C, M1, M0, M1, M3]` and reads `X` from `M0`; the chain would read `M3` (`[C, M1, M3, M0]`). The
    # indexer names the module's instance side unpositioned when one module is written to both tables, so
    # the chain is unsettled and every reader answers master's.
    it "settles to master where a module both prepends and includes the same module" do
      source = <<~RUBY
        module M0; X = :M0; end
        module M1; end
        module M3; X = :M3; end
        module M0; prepend M1; end
        class C; include M0; end
        module M0; include M1; end
        module M1; include M3; end
      RUBY
      Dir.mktmpdir("rigor-chain-witness-") do |dir|
        path = File.join(dir, "fixture.rb")
        File.write(path, source)
        expect(ruby_answers(path, { constants: ["C::X"] }).fetch("constants:C::X")).to eq("M0")
        scope = rigor_scope(source)
        chain = chain_of(scope, "C", :instance, :constants)
        expect(chain).to be_unsettled
        expect(chain.settle(scope, :answer) { raise "an unsettled chain reads no retro world" }).to eq(:master)
        expect(chain.instance_variable_get(:@retro)).to be_nil
      end
    end

    # CRuby propagates a later prepend into the includers of a prepended module and leaves a trailing
    # duplicate: `[M4, M3, M0, M4, Base]`. The first-occurrence order is the chain's; the duplicate is not
    # modelled, and no reader can tell the difference.
    it "matches Ruby's first-occurrence order where a later prepend propagates a trailing duplicate" do
      source = <<~RUBY
        module M0; def a = 0; end
        module M3; def b = 3; end
        module M4; def c = 4; end
        module M0; prepend M3; end
        class Base; prepend M0; end
        module M0; prepend M4; end
      RUBY
      Dir.mktmpdir("rigor-chain-witness-") do |dir|
        path = File.join(dir, "fixture.rb")
        File.write(path, source)
        ruby = ruby_answers(path, { ancestors: ["Base.instance"] }).fetch("ancestors:Base.instance").map(&:first)
        rigor = rigor_ancestors(rigor_scope(source), "Base.instance", %w[M0 M3 M4 Base], :methods, :skip).map(&:first)
        expect(ruby).to eq(%w[M4 M3 M0 M4 Base])
        expect(rigor).to eq(%w[M4 M3 M0 Base])
        expect(ruby.uniq).to eq(rigor)
      end
    end

    # A sibling shape with two forks, each an include skipped because `B` already carries the module: the
    # tables cannot say in which order `A` got `M` and `B` got `Z`, so the chain settles to master's order
    # (which here reaches `Z`, where this run of Ruby reaches `M`) rather than trust one interleaving.
    it "settles a chain with two include forks to master" do
      source = <<~RUBY
        module M; def foo = :m; end
        module Z; def foo = :z; end
        module A; include M; end
        class B; include Z; include M; end
        class C < B; include A; include Z; end
      RUBY
      Dir.mktmpdir("rigor-chain-witness-") do |dir|
        path = File.join(dir, "fixture.rb")
        File.write(path, source)
        expect(ruby_answers(path, { methods: ["C#foo"] }).fetch("C#foo").first.first).to eq("M")
        scope = rigor_scope(source)
        chain = chain_of(scope, "C")
        expect(chain.skip_count).to eq(2)
        expect(chain.settle(scope, :answer) { raise "two forks read no retro world" }).to eq(:master)
      end
    end

    # #1587 is fixed: the prepend table keeps every statement and the chain keeps the first, as Ruby's skip of a
    # module already in the prepend region does. #1573 is not: the extend table keeps the later statement's
    # position, which the folded singleton tables read, so a repeated `extend` names the singleton side
    # unpositioned and every reader answers what it always did. Flip this when #1573 is fixed: Ruby runs `E2`.
    it "leaves a repeated extend at the readers' own answer (#1573)" do
      source = <<~RUBY
        module E1
          def foo = :e1
        end

        module E2
          def foo = :e2
        end

        class C
          extend E1
          extend E2
          extend E1
        end
      RUBY
      Dir.mktmpdir("rigor-chain-witness-") do |dir|
        path = File.join(dir, "fixture.rb")
        File.write(path, source)
        ruby = ruby_answers(path, { methods: ["C.foo"] }).fetch("C.foo")
        expect(ruby.first).to eq(["E2", 6])
        scope = rigor_scope(source)
        expect(chain_of(scope, "C", :singleton)).to be_unsettled
        expect(rigor_agreed_singleton_line(scope, "C", :foo)).to eq(2)
      end
    end

    # Flip this when #1573 is fixed (the lane-2 producer change, ADR-119 WD7): the extend table keeps the first
    # position, the singleton chain settles, and the read answers the def Ruby runs (`E2`, line 6).
    it "reads a repeated extend at Ruby's first position (#1573)" do
      pending "https://github.com/rigortype/rigor/issues/1573 — fixed by the lane-2 record_extend_targets change; " \
              "the read answers E1's def (line 2)"

      source = <<~RUBY
        module E1
          def foo = :e1
        end

        module E2
          def foo = :e2
        end

        class C
          extend E1
          extend E2
          extend E1
        end
      RUBY
      expect(rigor_agreed_singleton_line(rigor_scope(source), "C", :foo)).to eq(6)
    end

    it "keeps a repeated prepend at its first position (#1587)" do
      source = <<~RUBY
        module P
          def foo = :p
        end

        module Q
          def foo = :q
        end

        class C
          prepend P
          prepend Q
          prepend P
        end
      RUBY
      Dir.mktmpdir("rigor-chain-witness-") do |dir|
        path = File.join(dir, "fixture.rb")
        File.write(path, source)
        ruby = ruby_answers(path, { methods: ["C#foo"] }).fetch("C#foo")
        expect(ruby.first).to eq(["Q", 6])
        expect(rigor_instance_definers(rigor_scope(source), "C", :foo).first).to eq(["Q", 6])
      end
    end
  end
end
