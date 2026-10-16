# frozen_string_literal: true

# The pin locator `bin/verify-changed` uses to run every "flip this when #N" example on an engine change
# (`tool/pin_examples.rb`). A wrong target either runs the wrong example — the pin then fails only in CI, the
# failure the locator exists to bring forward — or a whole group, which only costs time.
#
# Unit test only: requiring the script defines {PinExamples} without running it.
require "tmpdir"
require "spec_helper"

require_relative "../../tool/pin_examples"

RSpec.describe "tool/pin_examples.rb" do
  # Spelled apart so this file holds no pin of its own for the locator to find.
  let(:pin) { %w[Flip this when].join(" ") }

  let(:root) { Dir.mktmpdir("pin-examples") }

  after { FileUtils.rm_rf(root) }

  def locations_for(source)
    path = File.join(root, "sample_spec.rb")
    File.write(path, source)
    PinExamples.locations(root).map { |location| location.delete_prefix("#{path}:").to_i }
  end

  it "runs the example a pin comment introduces" do
    expect(locations_for(<<~RUBY)).to eq([4])
      RSpec.describe "x" do
        it("a") { expect(1).to eq(1) }
        # #{pin} #1 is fixed.
        it("b") { expect(1).to eq(1) }
      end
    RUBY
  end

  it "runs the example whose body holds the pin, from any line of a multi-line comment" do
    expect(locations_for(<<~RUBY)).to eq([3])
      RSpec.describe "x" do
        it("a") { expect(1).to eq(1) }
        it "b" do
          value = 1
          # Ruby answers 2 here; the expectation pins today's answer.
          # #{pin.downcase} #2 is fixed.
          expect(value).to eq(1)
        end
      end
    RUBY
  end

  it "runs the group a pin comment introduces" do
    expect(locations_for(<<~RUBY)).to eq([3])
      RSpec.describe "x" do
        # #{pin} #3 is fixed.
        describe "a group" do
          it("a") { expect(1).to eq(1) }
        end
      end
    RUBY
  end

  it "runs the enclosing group when the pin introduces no example" do
    expect(locations_for(<<~RUBY)).to eq([2])
      RSpec.describe "x" do
        describe "a group" do
          # #{pin} #4 is fixed.
          let(:value) { 1 }

          it("a") { expect(value).to eq(1) }
        end
      end
    RUBY
  end

  it "ignores the phrase outside a comment and in a header comment outside every block" do
    expect(locations_for(<<~RUBY)).to eq([])
      # A header that mentions the "#{pin.downcase} #N" convention.
      RSpec.describe "x" do
        it("says #{pin.downcase} #5 is fixed") { expect(1).to eq(1) }
      end
    RUBY
  end

  # A guard against a locator that silently finds nothing: the repository carries pins today, and each
  # location it names is an example or group opener.
  it "finds the repository's own pins, each on an example or group line" do
    locations = PinExamples.locations(File.expand_path("../../spec", __dir__))
    expect(locations).not_to be_empty
    locations.each do |location|
      path, line = location.split(/:(?=\d+\z)/)
      expect(File.readlines(path)[line.to_i - 1]).to match(PinExamples::OPENER), location
    end
  end
end
