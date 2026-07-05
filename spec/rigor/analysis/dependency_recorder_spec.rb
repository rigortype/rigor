# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-46 slice 1 — the cross-file dependency recorder. Verifies that analysing a file records the OTHER files its
# inference read from; `Incremental.invert` builds the `dependents` index from these records and the body tier
# re-analyses only the affected closure.
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
      # caller.rb's inference resolved Widget#price through to its body in model.rb, so model.rb is a recorded
      # dependency.
      expect(record.sources).to include(File.join(dir, "model.rb"))
      # A file does not depend on itself.
      expect(record.sources).not_to include(File.join(dir, "caller.rb"))
    end
  end

  it "records the superclass-defining file as a dependency (ADR-46 slice 1)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.rb"), <<~RUBY)
        class Base
          def greet
            "hi"
          end
        end
      RUBY
      File.write(File.join(dir, "child.rb"), <<~RUBY)
        class Child < Base
          def call_greet
            greet
          end
        end
      RUBY

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "child.rb")]

      # Resolving Child's `greet` walks the superclass chain through `superclass_of(Child)` and reads Base#greet's body
      # — both edges attribute to base.rb.
      expect(record.sources).to include(File.join(dir, "base.rb"))
    end
  end

  it "records a mixed-in module's file as a dependency (ADR-46 slice 1)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "mixin.rb"), <<~RUBY)
        module Greeter
          def greet
            "hi"
          end
        end
      RUBY
      File.write(File.join(dir, "host.rb"), <<~RUBY)
        class Host
          include Greeter
          def call_greet
            greet
          end
        end
      RUBY

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "host.rb")]

      # Resolving `greet` against the include chain reads `includes_of(Host)` and Greeter#greet's body — both attribute
      # to mixin.rb.
      expect(record.sources).to include(File.join(dir, "mixin.rb"))
    end
  end

  it "records every reopening file of a class whose ancestry is read (ADR-46 slice 1)" do
    Dir.mktmpdir do |dir|
      # `Account` is declared empty in one file and reopened with its superclass in another. A consumer that resolves an
      # inherited method depends on BOTH files — removing the superclass in the reopening must re-check the consumer, so
      # `superclass_of(Account)` records the full declaring-file set, not just the first declaration.
      File.write(File.join(dir, "account_decl.rb"), "class Account\nend\n")
      File.write(File.join(dir, "account_super.rb"), <<~RUBY)
        class Base
          def role
            "member"
          end
        end
        class Account < Base
        end
      RUBY
      File.write(File.join(dir, "consumer.rb"), <<~RUBY)
        class Account
          def whoami
            role
          end
        end
      RUBY

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "consumer.rb")]

      # The reopening that carries the superclass edge is a recorded source.
      expect(record.sources).to include(File.join(dir, "account_super.rb"))
      # And the empty earlier declaration, surfaced by the class-source set.
      expect(record.sources).to include(File.join(dir, "account_decl.rb"))
    end
  end

  it "inverts recorded sources into a dependents index (ADR-46 §2)" do
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
      dependents = runner.file_dependents

      # An edit to model.rb must re-check caller.rb (it read Widget#price's body from there), so caller.rb is a
      # dependent of model.rb.
      expect(dependents[File.join(dir, "model.rb")]).to include(File.join(dir, "caller.rb"))
      # A file no one reads from has no dependents entry (nil, not a mutable default — the frozen index dropped its
      # default proc).
      expect(dependents[File.join(dir, "caller.rb")]).to be_nil
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

  # ADR-46 slice 4 — symbol-granularity tracking.
  it "records method-call deps in symbol_sources (not ancestry_sources)" do
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

      model = File.join(dir, "model.rb")
      expect(record.symbol_sources[model]).to include("Widget#price")
      expect(record.ancestry_sources).not_to include(model)
    end
  end

  it "records superclass-of reads in ancestry_sources (file-level)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.rb"), <<~RUBY)
        class Base
          def greet
            "hi"
          end
        end
      RUBY
      File.write(File.join(dir, "child.rb"), <<~RUBY)
        class Child < Base
          def call_greet
            greet
          end
        end
      RUBY

      runner = run_recording(dir)
      record = runner.file_dependencies[File.join(dir, "child.rb")]

      base = File.join(dir, "base.rb")
      # The superclass ancestry read is file-level; the method body read is symbol-level.
      expect(record.ancestry_sources).to include(base)
      expect(record.symbol_sources[base]).to include("Base#greet")
    end
  end

  it "records runner#symbol_fingerprints keyed by path and symbol" do
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
      fps = runner.symbol_fingerprints

      model = File.join(dir, "model.rb")
      expect(fps[model]).to be_a(Hash)
      expect(fps[model].keys).to include("Widget#price")
      expect(fps[model]["Widget#price"]).to be_a(String).and have_attributes(length: 64)
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
