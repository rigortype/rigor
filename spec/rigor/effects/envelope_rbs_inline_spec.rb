# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"

RBS_INLINE_ENVELOPE_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-rbs-inline/lib", __dir__)
$LOAD_PATH.unshift(RBS_INLINE_ENVELOPE_PLUGIN_LIB) unless $LOAD_PATH.include?(RBS_INLINE_ENVELOPE_PLUGIN_LIB)
require "rigor-rbs-inline"

# ADR-103 WD5 (5) — the same envelope annotations, written in a `.rb` file through rbs-inline's
# `# @rbs %a{…}` form. Nothing extra implements this: rbs-inline's writer emits the `%a{}` onto the
# synthesized member, the synthesized RBS reaches the environment as a `virtual:` buffer, and the envelope
# scanner reads that buffer alongside the project's `sig/` tree. This example exists to PIN that path —
# it is undocumented and untested otherwise, and the handbook amendment that describes it is #384's.
RSpec.describe "effect envelopes written as rbs-inline comments" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def run_in(source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["demo.rb"], "plugins" => ["rigor-rbs-inline"], "effects" => {}
      )
    )
    Dir.mktmpdir("rigor-inline-envelope-") do |dir|
      File.write(File.join(dir, "demo.rb"), source)
      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          plugin_requirer: ->(_name) { Rigor::Plugin.register(Rigor::Plugin::RbsInline) }
        ).run(["demo.rb"]).diagnostics.select { |d| d.rule == "effect.envelope-exceeded" }
      end
    end
  end

  it "checks a `# @rbs %a{pure}` envelope against the method's proven effects" do
    diagnostics = run_in(<<~RUBY)
      # rbs_inline: enabled
      class Memo
        # @rbs %a{pure}
        # @rbs return: Integer
        def value
          @value ||= 42
        end
      end
    RUBY

    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.message).to include(
      "Method Memo#value performs mutate.self", "is declared %a{pure} at demo.rb:"
    )
    expect(diagnostics.first.path).to eq("demo.rb")
  end

  it "stays silent when the inline envelope admits what the method does" do
    diagnostics = run_in(<<~RUBY)
      # rbs_inline: enabled
      class Memo
        # @rbs %a{rigor:v1:effect mutate.self}
        # @rbs return: Integer
        def value
          @value ||= 42
        end
      end
    RUBY

    expect(diagnostics).to be_empty
  end
end
