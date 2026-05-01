# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::FileFolding do
  def file_singleton = Rigor::Type::Combinator.singleton_of("File")
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)

  def fold(method_name, *args)
    described_class.try_dispatch(
      receiver: file_singleton,
      method_name: method_name,
      args: args.map { |a| constant_of(a) }
    )
  end

  describe "path manipulation folds" do
    it "folds File.basename(path)" do
      expect(fold(:basename, "/foo/bar.rb")).to eq(constant_of("bar.rb"))
    end

    it "folds File.basename(path, ext)" do
      expect(fold(:basename, "/foo/bar.rb", ".rb")).to eq(constant_of("bar"))
    end

    it "folds File.dirname(path)" do
      expect(fold(:dirname, "/foo/bar.rb")).to eq(constant_of("/foo"))
    end

    it "folds File.extname(path)" do
      expect(fold(:extname, "hello.rb")).to eq(constant_of(".rb"))
      expect(fold(:extname, "hello")).to eq(constant_of(""))
    end

    it "folds File.join(parts...)" do
      expect(fold(:join, "a", "b", "c.rb")).to eq(constant_of("a/b/c.rb"))
    end

    it "folds File.split(path) to a Tuple[Constant, Constant]" do
      type = fold(:split, "/foo/bar.rb")
      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements).to eq([constant_of("/foo"), constant_of("bar.rb")])
    end

    it "folds File.absolute_path?(path)" do
      expect(fold(:absolute_path?, "/foo/bar")).to eq(constant_of(true))
      expect(fold(:absolute_path?, "foo/bar")).to eq(constant_of(false))
    end
  end

  describe "non-folding cases" do
    it "declines for unknown class methods" do
      # `File.read(path)` touches the filesystem — never fold.
      expect(fold(:read, "any.txt")).to be_nil
    end

    it "declines for non-Constant arguments" do
      result = described_class.try_dispatch(
        receiver: file_singleton,
        method_name: :basename,
        args: [Rigor::Type::Combinator.nominal_of("String")]
      )
      expect(result).to be_nil
    end

    it "declines for non-File receivers" do
      result = described_class.try_dispatch(
        receiver: Rigor::Type::Combinator.singleton_of("IO"),
        method_name: :basename,
        args: [constant_of("x")]
      )
      expect(result).to be_nil
    end

    it "declines for instance receivers (not Singleton[File])" do
      result = described_class.try_dispatch(
        receiver: Rigor::Type::Combinator.nominal_of("File"),
        method_name: :basename,
        args: [constant_of("x")]
      )
      expect(result).to be_nil
    end
  end
end
