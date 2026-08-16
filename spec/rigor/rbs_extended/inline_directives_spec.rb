# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"

RBS_EXTENDED_INLINE_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-rbs-inline/lib", __dir__)
$LOAD_PATH.unshift(RBS_EXTENDED_INLINE_PLUGIN_LIB) unless $LOAD_PATH.include?(RBS_EXTENDED_INLINE_PLUGIN_LIB)
require "rigor-rbs-inline"

# ADR-103 WD5 (5) / #384 — what is actually true about `%a{rigor:v1:…}` directives written in a `.rb`
# file, which is what the handbook amendment states.
#
# The mechanism is not per-directive: rbs-inline's writer copies a `# @rbs %a{…}` comment onto the
# generated member VERBATIM, `Environment.collect_virtual_rbs` merges the synthesized text into the
# same RBS environment the project's `sig/` tree lands in, and every directive reader walks
# `RBS::Definition::Method#annotations` off that one environment. So an inline directive is not a
# separate code path that could be supported one directive at a time — it is the same annotation
# object arriving through a different buffer.
#
# This example pins that claim with `rigor:v1:return:`, the directive whose effect is observable
# without any effects configuration at all: if it lands, the shared mechanism landed.
RSpec.describe "RBS::Extended directives written as rbs-inline comments" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def diagnostics_for(source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => ["demo.rb"], "plugins" => ["rigor-rbs-inline"])
    )
    Dir.mktmpdir("rigor-inline-directive-") do |dir|
      File.write(File.join(dir, "demo.rb"), source)
      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          plugin_requirer: ->(_name) { Rigor::Plugin.register(Rigor::Plugin::RbsInline) }
        ).run(["demo.rb"]).diagnostics
      end
    end
  end

  it "honours `rigor:v1:return:` from a `.rb` file, exactly as from a `.rbs` one" do
    dumped = diagnostics_for(<<~RUBY).select { |d| d.rule == "dump.type" }
      # rbs_inline: enabled
      class Reader
        # @rbs %a{rigor:v1:return: non-empty-string}
        # @rbs return: String
        def name
          "x"
        end
      end

      dump_type(Reader.new.name)
    RUBY

    expect(dumped.map(&:message)).to eq(["dump_type: non-empty-string"])
  end
end
