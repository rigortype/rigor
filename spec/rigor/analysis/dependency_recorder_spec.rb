# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-46 slice 1 — the cross-file dependency recorder. Verifies that
# analysing a file records the OTHER files its inference read from, so a
# later slice can invert this into a `dependents` index and re-analyse
# only the affected closure on an edit.
RSpec.describe Rigor::Analysis::DependencyRecorder do
  def run_recording(dir)
    configuration = Rigor::Configuration.new("paths" => [dir])
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration, cache_store: nil, record_dependencies: true
    )
    runner.run
    runner
  end

  it "records the defining file as a dependency of the calling file" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), <<~RUBY)
        class Widget
          def price
            100
          end
        end
      RUBY
      File.write(File.join(dir, "caller.rb"), "Widget.new.price\n")

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "caller.rb")]

      expect(record).not_to be_nil
      # caller.rb's inference resolved Widget#price through to its body in
      # model.rb, so model.rb is a recorded dependency.
      expect(record.sources).to include(File.join(dir, "model.rb"))
      # A file does not depend on itself.
      expect(record.sources).not_to include(File.join(dir, "caller.rb"))
    end
  end

  it "records a negative edge for an unresolved cross-class method call" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), "class Widget\nend\n")
      File.write(File.join(dir, "caller.rb"), "Widget.new.price\n")

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "caller.rb")]

      expect(record.missing).to include("method:Widget#price")
    end
  end

  it "records nothing when dependency recording is off (the default)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), "class Widget\n  def price\n    1\n  end\nend\n")
      File.write(File.join(dir, "caller.rb"), "Widget.new.price\n")

      configuration = Rigor::Configuration.new("paths" => [dir])
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
      runner.run

      expect(runner.file_dependencies).to be_empty
    end
  end
end
