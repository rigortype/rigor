# frozen_string_literal: true

require "spec_helper"
require "optionparser"
require "rigor/cli/renderable"

RSpec.describe Rigor::CLI::Renderable do
  subject(:renderer) { renderer_class.new }

  let(:renderer_class) do
    Class.new do
      include Rigor::CLI::Renderable

      attr_reader :calls

      def initialize
        @calls = []
      end

      def render_text(data) = (@calls << [:text, data])
      def render_json(data) = (@calls << [:json, data])
    end
  end

  it "routes text format to render_text" do
    renderer.render(:payload, format: "text")
    expect(renderer.calls).to eq([%i[text payload]])
  end

  it "routes json format to render_json" do
    renderer.render(:payload, format: "json")
    expect(renderer.calls).to eq([%i[json payload]])
  end

  it "raises a usage error naming the unsupported format" do
    expect { renderer.render(:payload, format: "csv") }
      .to raise_error(OptionParser::InvalidArgument, /unsupported format: csv/)
    expect(renderer.calls).to be_empty
  end
end
