# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/configuration"

# ADR-100 WD2 — `static.value-use.void`. A value recovered from an author-declared `-> void` return, used in
# value context, is a misuse: the author said "do not rely on this return", and the engine widened it to
# `top`. The diagnostic is FP-narrow (only an author-written `-> void`, only the direct-dispatch path) and,
# because a new required diagnostic is an ADR-50 WD1 compatibility change, it ships `:off` and reaches a user
# only through the `use-of-void-value` bleeding-edge feature.
#
# NOTE on the fixture method: the acceptance example `x = puts(1)` does not apply against rbs 4.0.2 — its
# `Kernel#puts` return is `nil`, not `void`. The rule's normative trigger is "an author *wrote* `-> void`", so
# the fixture declares one directly (`VoidBox#log`), which is the strongest form of the same case.
RSpec.describe "static.value-use.void reporting" do
  let(:void_box_rbs) do
    <<~RBS
      class VoidBox
        def log: (String) -> void
        def peek: () -> top
      end
    RBS
  end

  # Each call form pairs a `-> void` use (should fire when adopted) against a `-> top` use in the same value
  # position (must stay silent — the false-positive proof), plus a bare-statement `-> void` call (statement
  # context — accepted, silent).
  let(:app_rb) do
    <<~RUBY
      l = VoidBox.new
      assigned = l.log("assign")
      l.log("bare statement")
      l.log("receiver").to_s
      store(l.log("argument"))
      legit_assign = l.peek
      legit_recv = l.peek.to_s
    RUBY
  end

  def write_project
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "void_box.rbs"), void_box_rbs)
    File.write("app.rb", app_rb)
  end

  def config(bleeding_edge: nil)
    settings = Rigor::Configuration::DEFAULTS.merge(
      "paths" => %w[app.rb], "signature_paths" => %w[sig]
    )
    settings = settings.merge("bleeding_edge" => bleeding_edge) unless bleeding_edge.nil?
    Rigor::Configuration.new(settings)
  end

  def run(configuration)
    Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil).run(%w[app.rb])
  end

  def void_diagnostics(result)
    result.diagnostics.select { |d| d.rule == "static.value-use.void" }
  end

  around do |example|
    Dir.mktmpdir("rigor-void-value-use-") do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  it "fires nothing by default (the diagnostic is bleeding-edge-gated)" do
    write_project
    expect(void_diagnostics(run(config))).to be_empty
  end

  context "when the project adopts the use-of-void-value feature" do
    it "fires only on the value-context uses of the `-> void` return" do
      write_project
      diagnostics = void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))

      # The assignment (L2), receiver (L4), and argument (L5) uses fire; the bare statement (L3) and both
      # legitimate `-> top` uses (L6, L7) stay silent.
      expect(diagnostics.map(&:line)).to contain_exactly(2, 4, 5)
      expect(diagnostics).to all(have_attributes(severity: :warning))
      expect(diagnostics.first.message).to include("VoidBox#log", "-> void")
    end

    it "is adoptable via the `all` selector too" do
      write_project
      diagnostics = void_diagnostics(run(config(bleeding_edge: true)))
      expect(diagnostics.map(&:line)).to contain_exactly(2, 4, 5)
    end

    it "is suppressible with an in-source `# rigor:disable` comment" do
      FileUtils.mkdir_p("sig")
      File.write(File.join("sig", "void_box.rbs"), void_box_rbs)
      File.write("app.rb", <<~RUBY)
        l = VoidBox.new
        assigned = l.log("x") # rigor:disable static.value-use.void
      RUBY
      expect(void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))).to be_empty
    end
  end
end
