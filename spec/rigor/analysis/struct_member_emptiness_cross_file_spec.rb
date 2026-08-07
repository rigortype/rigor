# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #293 — the issue's verbatim two-file repro, kept at project level because that is where it was reported: the
# nested `Result = Struct.new(...)` only resolves for the consumer once the cross-file constant table records it
# (#271), and it was that resolution landing which first exposed the member pin behind it.
#
# `Result.new([], [])` used to pin `items` to the empty array literal. `r.items << Item.new(t)` fills the array on the
# very next line, but nothing retracted the pin, so the consumer's `.first` folded to `nil` and `.local` fired
# `call.undefined-method` on correct code. The gate that fixes it is the member map's, not the constant table's — so
# this file pins the FP silence and the still-working diagnostic side by side.
RSpec.describe "Struct member emptiness across files" do
  # Runs a two-file project and returns its `call.undefined-method` messages.
  def undefined_method_messages(defining, consumer)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "a.rb"), defining)
      File.write(File.join(lib, "b.rb"), consumer)
      result = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]), cache_store: nil
      ).run
      result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
    end
  end

  let(:empty_seeded_factory) do
    <<~RUBY
      module Pkg
        class Parser
          Result = Struct.new(:items, :errors)
          def self.parse(text)
            r = Result.new([], [])
            text.split(",").each { |t| r.items << Item.new(t) }
            r
          end
        end
        class Item
          def initialize(name) = @name = name
          def local = @name
        end
      end
    RUBY
  end

  # The same factory, seeded NON-empty and never mutated: the member keeps its literal, so the chain still carries a
  # real element type. This is the harness's "yes" — without it the silence above could equally mean the whole chain
  # had degraded to `Dynamic`, and the decline would pass for the wrong reason.
  let(:literal_seeded_factory) do
    <<~RUBY
      module Pkg
        class Builder
          Pair = Struct.new(:items, :errors)
          def self.build
            Pair.new(["a"], [])
          end
        end
      end
    RUBY
  end

  it "stays silent on a member filled by `<<` right after construction" do
    expect(undefined_method_messages(empty_seeded_factory, <<~RUBY)).to be_empty
      p Pkg::Parser.parse("a,b").items.first.local
    RUBY
  end

  it "still folds a never-mutated non-empty member precisely enough to report a typo on it" do
    expect(undefined_method_messages(literal_seeded_factory, <<~RUBY)).to include(a_string_matching(/zzz_undefined/))
      p Pkg::Builder.build.items.first.zzz_undefined
    RUBY
  end
end
