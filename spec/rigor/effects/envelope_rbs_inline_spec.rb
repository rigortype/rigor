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

  def run_in(source, signature: nil, plugins: ["rigor-rbs-inline"])
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["demo.rb"], "plugins" => plugins, "effects" => {}
      )
    )
    Dir.mktmpdir("rigor-inline-envelope-") do |dir|
      File.write(File.join(dir, "demo.rb"), source)
      if signature
        Dir.mkdir(File.join(dir, "sig"))
        File.write(File.join(dir, "sig", "demo.rbs"), signature)
      end
      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          plugin_requirer: ->(_name) { Rigor::Plugin.register(Rigor::Plugin::RbsInline) }
        ).run(["demo.rb"]).diagnostics.select { |d| d.rule == "effect.envelope-exceeded" }
      end
    end
  end

  # The declaration reference each message carries — "declared … at PATH:LINE".
  def declared_at(diagnostics)
    diagnostics.map { |diagnostic| diagnostic.message[/declared %a\{[^}]*\} at (\S+?),/, 1] }
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
      "Method Memo#value performs mutate.self", "is declared %a{pure} at demo.rb:3"
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

  # #432 — the declaration reference is the actionable half of the message: it says where to go to relax
  # or fix the bound. An rbs-inline annotation reaches the reader inside `RBS::Inline::Writer`'s output,
  # whose line numbers belong to a document nobody has, and the buffer still names the `.rb` — so the
  # message used to name a line in the licence header and read as plausible.
  #
  # Both lanes over ONE class, deliberately: the inline answer has two ways to be wrong that a
  # single-lane example cannot see. It can collapse to the `.rbs` lane's line number, which is what a
  # buffer-relative position looks like when the two documents happen to align, and it can collapse to a
  # file-level default, which any header line resembles. Two identically-bounded methods are here for the
  # third: a mapping that searches for the annotation's text alone answers the same line twice.
  describe "the declaration reference the message names (#432)" do
    let(:licence) do
      <<~RUBY
        # frozen_string_literal: true
        #
        # Copyright (C) 2006-2026 Someone
        #
        # This program is free software; you can redistribute it and/or
        # modify it under the terms of the GNU General Public License.
        #
      RUBY
    end

    it "names the `.rb` comment's own line for an rbs-inline declaration" do
      diagnostics = run_in(<<~RUBY)
        #{licence.chomp}
        # rbs_inline: enabled

        class Memo
          # @rbs %a{pure}
          def first
            @a ||= 1
          end

          # @rbs %a{pure}
          def second
            @b ||= 2
          end
        end
      RUBY

      expect(diagnostics.map(&:line)).to eq([12, 17])
      # The two `# @rbs %a{pure}` comments, at lines 11 and 16. Before the fix: `demo.rb:5` (inside the
      # licence) and `demo.rb:12` (the second method's bound, named at the first method's `def`).
      expect(declared_at(diagnostics)).to eq(["demo.rb:11", "demo.rb:16"])
    end

    it "names the `.rbs` line for the same class declared in the signature tree" do
      diagnostics = run_in(<<~RUBY, signature: <<~RBS, plugins: [])
        #{licence.chomp}
        class Memo
          def first
            @a ||= 1
          end

          def second
            @b ||= 2
          end
        end
      RUBY
        class Memo
          %a{pure}
          def first: () -> Integer

          %a{pure}
          def second: () -> Integer
        end
      RBS

      expect(diagnostics.map(&:line)).to eq([9, 13])
      expect(declared_at(diagnostics)).to eq(["sig/demo.rbs:2", "sig/demo.rbs:5"])
    end
  end
end
