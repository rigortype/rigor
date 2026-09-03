# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #271 — a nested `Const = Data.define(...)` must win Ruby's lexical constant lookup over a SAME-NAMED sibling in
# the parent namespace, from a consumer in another file.
#
# The cross-file discovery table (`ScopeIndexer.collect_class_decls`) recorded `class` / `module` declarations and
# `Const = Class.new(...)`, but not the Data/Struct constant-write forms; only the DEFINING file's `in_source_constants`
# knew about those, and that table is not part of the project seed. So when a consumer in another file adopted the
# inferred return of a factory defined here, `Result` inside the callee's body fell through the nested candidate to the
# parent namespace's sibling — and because that sibling is RBS-known (closed world), `call.undefined-method` fired on
# correct code with a receiver from an unrelated class.
#
# The RBS-known sibling is load-bearing, not decoration: without it the whole chain degrades to `Dynamic` and nothing
# fires, which is why the issue's first minimal repro came back clean.
RSpec.describe "cross-file nested Data constant resolution" do
  let(:sibling_rbs) do
    <<~RBS
      module M
        class Result
          attr_reader diagnostics: Array[untyped]
          def initialize: (?diagnostics: Array[untyped]) -> void
          def success?: () -> bool
        end
      end
    RBS
  end

  let(:defining_file) do
    <<~RUBY
      module M
        class Result
          attr_reader :diagnostics

          def initialize(diagnostics: [])
            @diagnostics = diagnostics
          end

          def success?
            diagnostics.empty?
          end
        end

        class Factory
          Result = Data.define(:digest) do
            def opaque?
              digest.nil?
            end
          end

          def self.build
            new.compute
          end

          def compute
            Result.new(digest: "x")
          end
        end
      end
    RUBY
  end

  # Runs a two-file project (the defining file plus `consumer`) with the sibling's RBS on `signature_paths:`.
  def undefined_method_messages(consumer)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      sig = File.join(dir, "sig")
      FileUtils.mkdir_p([lib, sig])
      File.write(File.join(lib, "a.rb"), defining_file)
      File.write(File.join(lib, "b.rb"), consumer)
      File.write(File.join(sig, "m.rbs"), sibling_rbs)
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib], "signature_paths" => [sig]),
        cache_store: nil
      )
      result = guarded_run(runner)
      result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
    end
  end

  it "does not attribute a two-hop factory return to the parent namespace's sibling" do
    expect(undefined_method_messages(<<~RUBY)).to be_empty
      module M
        class Consumer
          def run
            M::Factory.build.opaque?
          end
        end
      end
    RUBY
  end

  it "does not attribute a one-hop instance-method return to the sibling either" do
    expect(undefined_method_messages(<<~RUBY)).to be_empty
      module M
        class Consumer
          def run
            M::Factory.new.compute.opaque?
          end
        end
      end
    RUBY
  end

  # The harness must be able to say "yes": the sibling is genuinely closed, so a real typo on IT still fires. Without
  # this the two examples above would pass on a build that had simply stopped analysing the file.
  it "still reports a genuine undefined method on the sibling itself" do
    expect(undefined_method_messages(<<~RUBY)).to include(a_string_matching(/M::Result/))
      module M
        class Consumer
          def run
            M::Result.new.zzz_undefined
          end
        end
      end
    RUBY
  end
end
