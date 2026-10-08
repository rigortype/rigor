# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-119 C2-b1's `bot` exception — an UNKNOWN typing read types a call `bot` where every project definer of the
# name on the receiver's chain types `bot`. The answer reads every project entry of the chain, including those
# past the first candidate that `DefinerResolution`'s decline never filed, so a file that adds a returning
# definer to any of them must re-check the caller. The oracle is a full `--no-cache` run of the same tree; the
# driver is `IncrementalSession`, as in `prepend_region_incremental_spec.rb`.
RSpec.describe "typing read's bot exception — incremental" do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [dir])
  end

  def shared_environment
    @shared_environment ||= Rigor::Environment.for_project
  end

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(
      configuration: configuration(dir), paths: [dir], environment: shared_environment
    )
  end

  def reported(diagnostics)
    found = diagnostics.reject { |d| d.severity == :info }
    found.map { |d| [File.basename(d.path), d.line, d.qualified_rule] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir), cache_store: nil, environment: shared_environment
    )
    reported(guarded_run(runner).diagnostics)
  end

  let(:media) do
    <<~RUBY
      class Media < Base
        include ActionView::Helpers::NumberHelper

        def lookup(list)
          count = [7, 10].find { |n| n <= list.length }
          fail_with "no" unless count
          list[-count..]
        end
      end
    RUBY
  end

  # `Root#fail_with` sits past `Base#fail_with`, the first candidate, so the decline (the RBS-unknown module ahead
  # of `Base`) filed nothing for it; the exception counts every definer on the chain whatever its position, so the
  # new returning `def` turns the call `Dynamic` and the guard stops narrowing. Warm must say what cold says. (The
  # self call's existence read files `Root`'s class edges too, so this pins the outcome, not which reader filed it.)
  it "re-checks the caller when a new file adds a returning definer past the first candidate" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.rb"), <<~RUBY)
        class Root
          def other = 1
        end

        class Base < Root
          def fail_with(message)
            raise ArgumentError, message
          end
        end
      RUBY
      File.write(File.join(dir, "media.rb"), media)

      session = session_for(dir)
      expect(reported(guarded_baseline(session))).to eq([])
      expect(full_run(dir)).to eq([])

      File.write(File.join(dir, "root_ext.rb"), "class Root\n  def fail_with(_message) = nil\nend\n")
      cold = full_run(dir)
      expect(cold).to eq([["media.rb", 7, "call.possible-nil-receiver"]])
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(File.join(dir, "media.rb"))
      expect(reported(recheck.diagnostics)).to eq(cold)
    end
  end
end
