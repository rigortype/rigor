# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::ShellwordsFolding do
  def sw_singleton = Rigor::Type::Combinator.singleton_of("Shellwords")
  def c(value)     = Rigor::Type::Combinator.constant_of(value)
  def tuple(*elems) = Rigor::Type::Combinator.tuple_of(*elems)

  def fold(method_name, *arg_types)
    described_class.try_dispatch(
      receiver: sw_singleton,
      method_name: method_name,
      args: arg_types
    )
  end

  # ── escape / shellescape ─────────────────────────────────────────────

  describe "escape / shellescape" do
    it "escapes a plain string" do
      expect(fold(:escape, c("hello"))).to eq(c("hello"))
    end

    it "escapes a string with spaces and special chars" do
      expect(fold(:escape, c("hello world"))).to eq(c("hello\\ world"))
    end

    it "escapes an empty string to ''" do
      # Shellwords.escape("") => "''" — non-empty even for empty input
      expect(fold(:escape, c(""))).to eq(c("''"))
    end

    it "treats shellescape as an alias" do
      expect(fold(:shellescape, c("a b"))).to eq(fold(:escape, c("a b")))
    end

    it "declines for a non-Constant argument" do
      expect(fold(:escape, Rigor::Type::Combinator.nominal_of("String"))).to be_nil
    end

    it "declines for a non-String constant" do
      expect(fold(:escape, c(42))).to be_nil
    end

    it "declines when more than one argument is given" do
      expect(fold(:escape, c("a"), c("b"))).to be_nil
    end
  end

  # ── split / shellsplit / shellwords ──────────────────────────────────

  describe "split / shellsplit / shellwords" do
    it "splits a simple command line" do
      result = fold(:split, c("echo hello world"))
      expect(result).to be_a(Rigor::Type::Tuple)
      expect(result.elements).to eq([c("echo"), c("hello"), c("world")])
    end

    it "handles quoted tokens" do
      result = fold(:split, c("git commit -m 'initial commit'"))
      expect(result).to be_a(Rigor::Type::Tuple)
      expect(result.elements).to eq([c("git"), c("commit"), c("-m"), c("initial commit")])
    end

    it "returns an empty Tuple for an empty string" do
      result = fold(:split, c(""))
      expect(result).to be_a(Rigor::Type::Tuple)
      expect(result.elements).to be_empty
    end

    it "treats shellsplit as an alias" do
      expect(fold(:shellsplit, c("ls -la"))).to eq(fold(:split, c("ls -la")))
    end

    it "treats shellwords as an alias" do
      expect(fold(:shellwords, c("ls -la"))).to eq(fold(:split, c("ls -la")))
    end

    it "declines for unmatched quotes (would raise ArgumentError)" do
      expect(fold(:split, c("echo 'unclosed"))).to be_nil
    end

    it "declines for a non-Constant argument" do
      expect(fold(:split, Rigor::Type::Combinator.nominal_of("String"))).to be_nil
    end

    it "declines when more than one argument is given" do
      expect(fold(:split, c("a b"), c("x"))).to be_nil
    end
  end

  # ── join / shelljoin ──────────────────────────────────────────────────

  describe "join / shelljoin" do
    it "joins an array of plain tokens" do
      arg = tuple(c("echo"), c("hello"), c("world"))
      expect(fold(:join, arg)).to eq(c("echo hello world"))
    end

    it "escapes tokens with spaces" do
      # Shellwords.join uses Shellwords.escape per token, which
      # backslash-escapes rather than quoting: "initial commit" → "initial\ commit"
      arg = tuple(c("git"), c("commit"), c("-m"), c("initial commit"))
      expect(fold(:join, arg)).to eq(c("git commit -m initial\\ commit"))
    end

    it "returns an empty string for an empty Tuple" do
      expect(fold(:join, tuple)).to eq(c(""))
    end

    it "treats shelljoin as an alias" do
      arg = tuple(c("ls"), c("-la"))
      expect(fold(:shelljoin, arg)).to eq(fold(:join, arg))
    end

    it "declines when the argument is not a Tuple" do
      expect(fold(:join, Rigor::Type::Combinator.nominal_of("Array"))).to be_nil
    end

    it "declines when a Tuple element is not a Constant[String]" do
      arg = tuple(c("echo"), Rigor::Type::Combinator.nominal_of("String"))
      expect(fold(:join, arg)).to be_nil
    end

    it "declines when a Tuple element is a non-String Constant" do
      arg = tuple(c("echo"), c(42))
      expect(fold(:join, arg)).to be_nil
    end

    it "declines when more than one argument is given" do
      expect(fold(:join, tuple(c("a")), c("extra"))).to be_nil
    end
  end

  # ── dispatch_target? guard ────────────────────────────────────────────

  describe "receiver identity guard" do
    it "declines for a non-Shellwords singleton" do
      result = described_class.try_dispatch(
        receiver: Rigor::Type::Combinator.singleton_of("File"),
        method_name: :escape,
        args: [c("x")]
      )
      expect(result).to be_nil
    end

    it "declines for a Nominal[Shellwords] instance receiver" do
      result = described_class.try_dispatch(
        receiver: Rigor::Type::Combinator.nominal_of("Shellwords"),
        method_name: :escape,
        args: [c("x")]
      )
      expect(result).to be_nil
    end

    it "declines for an unsupported method on the correct receiver" do
      expect(fold(:nonexistent, c("x"))).to be_nil
    end
  end

  # ── split round-trips through join ───────────────────────────────────

  describe "split/join round-trip" do
    it "Shellwords.join(Shellwords.split(cmd)) reconstructs the command" do
      cmd = "git commit -m 'hello world'"
      tokens_type = fold(:split, c(cmd))
      rejoined    = fold(:join, tokens_type)
      expect(rejoined).to eq(c(Shellwords.join(Shellwords.split(cmd))))
    end
  end
end
