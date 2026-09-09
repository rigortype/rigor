# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #661 — `Kernel#<=>: (untyped other) -> 0?` reached by inheritance.
#
# The literal `0` is the identity comparison — `0` when the two are the same object, `nil` otherwise —
# and it is the truth about a bare `Object`. On a receiver that merely INHERITS it, it is a value-precise
# claim about an operator the receiver's signature was never required to mention, and the cost does not
# stay in the expression: it narrows.
RSpec.describe "inherited Kernel#<=> return envelope" do
  let(:environment) { Rigor::Environment.default }

  def dispatch(receiver)
    Rigor::Inference::MethodDispatcher::RbsDispatch.try_dispatch(
      cc(receiver: receiver, method_name: :<=>, args: [], environment: environment)
    )
  end

  def nominal(klass)
    Rigor::Type::Combinator.nominal_of(klass)
  end

  # `Hash` is core's witness: it declares no `<=>` of its own, so resolution walks to Kernel's.
  it "widens an inherited Kernel#<=> to the Integer? envelope" do
    expect(dispatch(nominal(Hash)).describe(:short)).to eq("Integer?")
  end

  # The owners keep the claim: on `Object` itself the identity comparison IS what runs, and reading it as
  # `Integer?` there would be precision given away for nothing.
  it "leaves the identity comparison intact on the class that owns it" do
    expect(dispatch(nominal(Object)).describe(:short)).to eq("0?")
  end

  # `BasicObject` does not include `Kernel`, so it has no `<=>` at all — the guard must not mint one for
  # a receiver whose surface genuinely lacks the operator.
  it "invents no comparison on a receiver that has none" do
    expect(dispatch(nominal(BasicObject))).to be_nil
  end

  # A class that DECLARES `<=>` is untouched — including where its own return is more precise than the
  # envelope, which is how a widening applied too broadly would show up here.
  it "leaves a declared #<=> alone" do
    expect(dispatch(nominal(Time)).describe(:short)).to eq("Integer")
    expect(dispatch(nominal(String)).describe(:short)).to eq("-1 | 0 | 1")
  end

  # What the `0?` actually cost. `Money`'s signature says `include Comparable`, whose entire contract is
  # that the includer defines `<=>`; it declares no `<=>`, so Kernel's answered. Narrowing the result to
  # truthy then read it as the literal `0`, folded `0.negative?` to false, and typed the branch `bot` — a
  # branch the runtime takes on every ordered pair, one `clause.unreachable` from a false positive.
  it "does not fold a comparison branch to bot on a Comparable receiver" do
    types = dump_types(<<~RBS, <<~RUBY)
      class Money
        include Comparable
      end

      class App
        def self.money: () -> Money
      end
    RBS
      n = App.money <=> App.money
      Rigor.dump_type(n)
      if n && n.negative?
        Rigor.dump_type(n)
      end
    RUBY

    expect(types).to eq(["Integer?", "negative-int"])
  end

  def dump_types(rbs, source)
    Dir.mktmpdir("spaceship-envelope-") do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p("sig")
        File.write(File.join("sig", "app.rbs"), rbs)
        File.write("app.rb", source)
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge("paths" => %w[app.rb], "signature_paths" => %w[sig])
        )
        runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
        dumps = guarded_run(runner, %w[app.rb]).diagnostics.select { |d| d.rule == "dump.type" }
        dumps.map { |d| d.message.sub(/\Adump_type: /, "") }
      end
    end
  end
end
