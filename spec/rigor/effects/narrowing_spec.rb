# frozen_string_literal: true

require "spec_helper"

# Argument-dependent narrowing (ADR-103 WD3, #380). Each handler reads the call's OWN argument literals
# and nothing else — no dataflow, no inference — and answers an upper bound whenever the literals do not
# settle the question.
RSpec.describe Rigor::Effects::Narrowing do
  # The catalogue answer for `source`, taken through the loader rather than the handler directly, so the
  # row's `narrow:` wiring is under test alongside the handler.
  def labels_for(source, owner:, selector:, singleton: false)
    node = Prism.parse(source).value.statements.body.first
    raise ArgumentError, "not a call: #{source}" unless node.is_a?(Prism::CallNode)

    Rigor::Effects::Catalog.default
                           .lookup(owner, selector, singleton: singleton, call_node: node)
                           .labels.to_a
  end

  describe "Kernel#open" do
    def open_labels(source)
      labels_for(source, owner: "Kernel", selector: "open")
    end

    it "reads a literal path" do
      expect(open_labels('open("/etc/hosts")')).to eq(["io.fs.read"])
    end

    it "writes a literal path under a write mode" do
      expect(open_labels('open("/tmp/x", "w")')).to eq(["io.fs.write"])
    end

    it "reads and writes under an update mode" do
      expect(open_labels('open("/tmp/x", "r+")')).to eq(%w[io.fs.read io.fs.write])
    end

    # The classic pipe-injection footgun, made visible in the summary.
    it "runs a subprocess for a literal leading pipe" do
      expect(open_labels('open("|ls -l")')).to eq(["io.process"])
    end

    # The part that decides the subsystem is written out even when the rest is computed.
    it "reads the literal head of an interpolated argument" do
      expect(open_labels("open(\"|\#{cmd}\")")).to eq(["io.process"])
    end

    it "answers the parent label when the argument is not a literal" do
      expect(open_labels("open(path)")).to eq(["io"])
    end
  end

  describe "File.open" do
    def file_open_labels(source)
      labels_for(source, owner: "File", selector: "open", singleton: true)
    end

    # An ABSENT mode is not an unknown one: Ruby's default is `"r"`.
    it "reads when no mode is given" do
      expect(file_open_labels("File.open(path)")).to eq(["io.fs.read"])
    end

    it "reads under an explicit read mode, ignoring the encoding suffix" do
      expect(file_open_labels('File.open(path, "r:UTF-8")')).to eq(["io.fs.read"])
    end

    %w[w a].each do |mode|
      it "writes under mode #{mode.inspect}" do
        expect(file_open_labels(%(File.open(path, "#{mode}")))).to eq(["io.fs.write"])
      end
    end

    %w[r+ w+ a+].each do |mode|
      it "reads and writes under mode #{mode.inspect}" do
        expect(file_open_labels(%(File.open(path, "#{mode}")))).to eq(%w[io.fs.read io.fs.write])
      end
    end

    it "reads the mode from a keyword argument" do
      expect(file_open_labels('File.open(path, mode: "w")')).to eq(["io.fs.write"])
    end

    # A computed mode — or an integer flag such as `File::RDWR`, which the scan deliberately does not
    # resolve — answers the subsystem parent rather than guessing a direction.
    it "answers the subsystem parent for a mode it cannot read" do
      expect(file_open_labels("File.open(path, mode)")).to eq(["io.fs"])
      expect(file_open_labels("File.open(path, File::RDWR)")).to eq(["io.fs"])
    end

    it "narrows Pathname#open through the same handler" do
      expect(labels_for('handle.open("w")', owner: "Pathname", selector: "open")).to eq(["io.fs.write"])
    end
  end

  describe "Time.new" do
    def time_new_labels(source)
      labels_for(source, owner: "Time", selector: "new", singleton: true)
    end

    it "reads the clock with no arguments" do
      expect(time_new_labels("Time.new")).to eq(["nondet.time"])
    end

    it "consults nothing when constructed from arguments" do
      expect(time_new_labels("Time.new(2020, 1, 1)")).to eq([])
    end

    # `Time.new(in: "+09:00")` is still now — keyword arguments do not make it a construction.
    it "still reads the clock when only a keyword argument is given" do
      expect(time_new_labels('Time.new(in: "+09:00")')).to eq(["nondet.time"])
    end

    it "leaves Time.now unconditional" do
      expect(labels_for("Time.now", owner: "Time", selector: "now", singleton: true)).to eq(["nondet.time"])
    end
  end

  describe "Random.new" do
    def random_new_labels(source)
      labels_for(source, owner: "Random", selector: "new", singleton: true)
    end

    it "draws platform entropy with no seed" do
      expect(random_new_labels("Random.new")).to eq(["nondet.random"])
    end

    it "is reproducible from the source with a seed" do
      expect(random_new_labels("Random.new(42)")).to eq([])
    end
  end

  describe "URI.open" do
    def uri_open_labels(source)
      labels_for(source, owner: "URI", selector: "open", singleton: true)
    end

    it "speaks HTTP for an http(s) literal" do
      expect(uri_open_labels('URI.open("https://example.com/x")')).to eq(["io.net.http"])
      expect(uri_open_labels('URI.open("http://example.com/x")')).to eq(["io.net.http"])
    end

    it "reads the literal head of an interpolated URL" do
      expect(uri_open_labels("URI.open(\"https://\#{host}/x\")")).to eq(["io.net.http"])
    end

    it "reads the filesystem for a file:// literal or a bare path" do
      expect(uri_open_labels('URI.open("file:///etc/hosts")')).to eq(["io.fs.read"])
      expect(uri_open_labels('URI.open("/etc/hosts")')).to eq(["io.fs.read"])
    end

    it "answers the parent for a scheme nobody rowed" do
      expect(uri_open_labels('URI.open("ftp://example.com/x")')).to eq(["io"])
    end

    it "answers the parent when the argument is not a literal" do
      expect(uri_open_labels("URI.open(endpoint)")).to eq(["io"])
    end

    it "narrows OpenURI.open_uri through the same handler" do
      expect(labels_for('OpenURI.open_uri("https://example.com")', owner: "OpenURI", selector: "open_uri",
                                                                   singleton: true))
        .to eq(["io.net.http"])
    end
  end

  it "answers nil for a handler it does not implement" do
    expect(described_class.known?("nope")).to be(false)
    expect(described_class.apply("nope", nil)).to be_nil
  end
end
