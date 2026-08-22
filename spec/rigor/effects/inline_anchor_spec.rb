# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/effects/inline_anchor"

# #432 — the mapping from a synthesized RBS buffer's line back onto the Ruby file the author wrote in.
# The end-to-end pin over the real rbs-inline writer is `spec/rigor/effects/envelope_rbs_inline_spec.rb`;
# this covers the mapping's own edges, which that one cannot reach through a plugin.
RSpec.describe Rigor::Effects::InlineAnchor do
  around do |example|
    Dir.mktmpdir("rigor-inline-anchor-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(path, source)
    File.write(path, source)
    path
  end

  # What `RBS::Inline::Writer` actually emits: the author's comment block echoed above the member, then
  # the annotation the RBS parser reads, then the signature. The echo is why a naive count is wrong.
  let(:buffer) do
    <<~RBS
      class Memo
        # @rbs %a{pure}
        %a{pure}
        def first: () -> Integer

        def filler: () -> untyped

        # @rbs %a{pure}
        %a{pure}
        def second: () -> Integer
      end
    RBS
  end

  let(:ruby) do
    <<~RUBY
      # Copyright (C) 2026 Someone
      #
      # Licensed under the terms of something long.

      class Memo
        # @rbs %a{pure}
        def first
          @a ||= 1
        end

        def filler
          2
        end

        # @rbs %a{pure}
        def second
          @b ||= 3
        end
      end
    RUBY
  end

  it "answers the `.rb` line the annotation was written on, not the buffer's" do
    write("demo.rb", ruby)

    expect(described_class.ruby_line(path: "demo.rb", buffer: buffer, buffer_line: 3)).to eq(6)
  end

  # The failure the ordinal exists for: two methods bounded the same way. Matching on text alone sends
  # both findings to the first annotation, which is as unactionable as the buffer line was.
  it "distinguishes two identically-spelled annotations by their order" do
    write("demo.rb", ruby)

    expect(described_class.ruby_line(path: "demo.rb", buffer: buffer, buffer_line: 9)).to eq(15)
  end

  it "takes the caller's spelling when it has one" do
    write("demo.rb", ruby)

    line = described_class.ruby_line(path: "demo.rb", buffer: buffer, buffer_line: 9, spelling: "%a{pure}")
    expect(line).to eq(15)
  end

  it "never maps a `.rbs` buffer, whose own line numbers are already openable" do
    expect(described_class.for(path: "sig/demo.rbs", buffer: buffer)).to be_nil
    expect(described_class.ruby_line(path: "sig/demo.rbs", buffer: buffer, buffer_line: 3)).to eq(3)
  end

  describe "degradation" do
    it "keeps the buffer line when the Ruby file cannot be read" do
      expect(described_class.ruby_line(path: "absent.rb", buffer: buffer, buffer_line: 3)).to eq(3)
    end

    it "keeps the buffer line when the spelling appears nowhere in the Ruby file" do
      write("demo.rb", "class Memo\nend\n")

      expect(described_class.ruby_line(path: "demo.rb", buffer: buffer, buffer_line: 3)).to eq(3)
    end

    it "keeps the buffer line when the buffer line carries no annotation at all" do
      write("demo.rb", ruby)

      expect(described_class.ruby_line(path: "demo.rb", buffer: buffer, buffer_line: 1)).to eq(1)
    end

    # Fewer matches in the `.rb` than in the buffer means the order assumption broke somewhere. The
    # first match is a position in the right neighbourhood; an exception would cost the whole finding.
    it "falls back to the first match when the ordinal runs off the end" do
      write("demo.rb", "class Memo\n  # @rbs %a{pure}\n  def first\n  end\nend\n")

      expect(described_class.ruby_line(path: "demo.rb", buffer: buffer, buffer_line: 9)).to eq(2)
    end

    it "ignores an annotation-shaped string literal, which is code rather than a declaration" do
      write("demo.rb", "class Memo\n  MARKER = \"%a{pure}\"\n  # @rbs %a{pure}\n  def first\n  end\nend\n")

      expect(described_class.ruby_line(path: "demo.rb", buffer: buffer, buffer_line: 3)).to eq(3)
    end
  end
end
