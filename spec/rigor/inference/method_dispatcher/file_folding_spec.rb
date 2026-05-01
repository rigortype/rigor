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

  # Toggle the module-global flag for the duration of a single
  # test; restore it afterwards so other specs see the default.
  around do |example|
    original = described_class.fold_platform_specific_paths
    example.run
  ensure
    described_class.fold_platform_specific_paths = original
  end

  describe "default platform-agnostic mode" do
    before { described_class.fold_platform_specific_paths = false }

    it "declines every path-manipulation method by default" do
      expect(fold(:basename, "/foo/bar.rb")).to be_nil
      expect(fold(:dirname, "/foo/bar.rb")).to be_nil
      expect(fold(:extname, "hello.rb")).to be_nil
      expect(fold(:join, "a", "b", "c.rb")).to be_nil
      expect(fold(:split, "/foo/bar.rb")).to be_nil
      expect(fold(:absolute_path?, "/foo")).to be_nil
    end
  end

  describe "opt-in platform-specific mode" do
    before { described_class.fold_platform_specific_paths = true }

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
    end
  end

  describe "non-folding cases (independent of mode)" do
    before { described_class.fold_platform_specific_paths = true }

    it "declines for unknown class methods" do
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
