# frozen_string_literal: true

require "spec_helper"
require "yaml"

# The String twin of #1253's `Hash#shift`. `Inference::StringMutation::MUTATORS` did not list `delete_prefix!`,
# `delete_suffix!`, `encode!`, `scrub!`, `unicode_normalize!`, `setbyte`, `bytesplice` or `append_as_bytes`, so every
# seam that widens a String literal declined them and the literal outlived the mutation: `s = +"ab";
# s.delete_prefix!("a")` kept `"ab"` for a receiver holding `"b"`, and `s == "ab"` folded always-truthy on correct
# code. The class-level ivar and constant censuses, the indexed-narrowing invalidation and the callee and
# escaping-closure floors read only the Array and Hash tables, so they missed even the names the String table did list.
#
# Every mutating example is paired with a control that makes a non-mutating call in the same position, and the control
# must keep the literal — without it, a seam that stopped folding altogether would pass the mutating half too. Each
# call a fixture makes is also run under Ruby here, so the claim that it moves (or empties) the receiver is checked
# rather than asserted.
RSpec.describe "String mutation widening", type: :runner do
  def diagnostics(source, sig)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig).diagnostics
  end

  def dumped_types(source, sig: {})
    diagnostics(source, sig).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def flow_rules(source, sig: {})
    diagnostics(source, sig).filter_map do |diagnostic|
      diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.")
    end
  end

  # The receiver after running `call` on a mutable copy of `literal` under Ruby.
  def run(literal, call)
    literal.dup.tap { |receiver| receiver.instance_eval(call, __FILE__, __LINE__) }
  end

  # Each mutator the table was missing, called so that it moves the literal, beside a non-mutating sibling.
  [
    ["ab", 'delete_prefix!("a")', 'delete_prefix("a")'],
    ["ab", 'delete_suffix!("b")', 'delete_suffix("b")'],
    ["ab", 'encode!("UTF-16LE")', 'encode("UTF-16LE")'],
    ["a\xFF", 'scrub!("")', 'scrub("")'],
    ["é", "unicode_normalize!(:nfd)", "unicode_normalize(:nfd)"],
    ["ab", "setbyte(0, 98)", "getbyte(0)"],
    ["ab", 'bytesplice(0, 1, "")', "byteslice(0, 1)"],
    ["ab", 'append_as_bytes("c")', "bytesize"]
  ].each do |literal, mutator, sibling|
    describe "`#{mutator}`" do
      let(:source_literal) { literal.inspect }

      it "moves the receiver at runtime, where the sibling does not" do
        expect(run(literal, mutator)).not_to eq(literal)
        expect(run(literal, sibling)).to eq(literal)
      end

      it "widens a local literal on the straight-line seam, and keeps one the sibling only reads" do
        expect(dumped_types(<<~RUBY)).to eq(["String", source_literal])
          s = +#{source_literal}
          s.#{mutator}
          dump_type(s)
          t = +#{source_literal}
          t.#{sibling}
          dump_type(t)
        RUBY
      end

      it "stops the comparison folding, and keeps the fold under the sibling" do
        expect(flow_rules(<<~RUBY)).to be_empty
          s = +#{source_literal}
          s.#{mutator}
          puts "same" if s == #{source_literal}
        RUBY
        expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
          s = +#{source_literal}
          s.#{sibling}
          puts "same" if s == #{source_literal}
        RUBY
      end

      # ADR-56 slice A: a captured outer local mutated inside a block widens in the outer scope after the call.
      it "widens a captured literal the block mutates, and keeps one the block only reads" do
        expect(dumped_types(<<~RUBY)).to eq(["String", source_literal])
          s = +#{source_literal}
          [1].each { s.#{mutator} }
          dump_type(s)
          t = +#{source_literal}
          [1].each { t.#{sibling} }
          dump_type(t)
        RUBY
      end

      # The per-element Tuple fold types every position from one entry scope; a captured literal the body mutates
      # in place is widened for an unknown store first, or every position reads the entry size.
      it "does not pin the entry size of a captured literal the per-element fold mutates" do
        expect(dumped_types(<<~RUBY)).to eq(["[non-negative-int, non-negative-int]", "[2, 2]"])
          s = +#{source_literal}
          dump_type([1, 2].map { |i| v = s.bytesize; s.#{mutator}; v })
          t = +#{source_literal}
          dump_type([1, 2].map { |i| v = t.bytesize; t.#{sibling}; v })
        RUBY
      end
    end
  end

  # ADR-58: a literal ivar seed is widened at every method entry when some method in the class mutates the ivar. The
  # census had no String arm, so even `<<` — a name the table always listed — left the seed pinned.
  describe "the class-level ivar census" do
    it "widens a String seed another method mutates, and keeps one another method only reads" do
      expect(dumped_types(<<~RUBY)).to eq(["String", "String", "String", '"ab"'])
        class Appended
          def initialize = @s = +"ab"
          def add = @s << "c"
          def peek = dump_type(@s)
        end

        class Stripped
          def initialize = @s = +"ab"
          def drop = @s.delete_prefix!("a")
          def peek = dump_type(@s)
        end

        class Aliased
          def initialize = @s = +"ab"
          def buffer = @s
          def drop = buffer.delete_prefix!("a")
          def peek = dump_type(@s)
        end

        class Kept
          def initialize = @s = +"ab"
          def read = @s.delete_prefix("a")
          def peek = dump_type(@s)
        end
      RUBY
    end

    it "does not fold a sibling method's comparison against the seed" do
      expect(flow_rules(<<~RUBY)).to be_empty
        class Appended
          def initialize = @s = +"ab"
          def add = @s << "c"

          def same?
            puts "same" if @s == "ab"
          end
        end
      RUBY
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        class Kept
          def initialize = @s = +"ab"
          def read = @s.delete_prefix("a")

          def same?
            puts "same" if @s == "ab"
          end
        end
      RUBY
    end
  end

  # The constant census widens a constant some method mutates in place, keyed on the mutator's name alone.
  describe "the constant census" do
    it "does not fold a comparison against a String constant a method mutates" do
      expect(flow_rules(<<~RUBY)).to be_empty
        module Box
          BUF = +"ab"
          def self.drop = BUF.delete_prefix!("a")

          def self.same?
            puts "same" if BUF == "ab"
          end
        end
      RUBY
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        module Box
          BUF = +"ab"
          def self.read = BUF.delete_prefix("a")

          def self.same?
            puts "same" if BUF == "ab"
          end
        end
      RUBY
    end
  end

  # A `receiver[key] ||= default` narrowing is dropped when a mutator runs against the receiver; the String mutators
  # were not among the ones that dropped it.
  describe "the indexed narrowing" do
    it "drops a slot narrowing when a String mutator rewrites the receiver" do
      expect(run("", '(self[0] ||= "x"; delete_prefix!("x"))')[0]).to be_nil
      expect(dumped_types(<<~RUBY)).to eq(["String?", '"x" | String'])
        s = String.new("")
        s[0] ||= "x"
        s.delete_prefix!("x")
        dump_type(s[0])
        t = String.new("")
        t[0] ||= "x"
        t.delete_prefix("x")
        dump_type(t[0])
      RUBY
    end

    # The mutator rewrites the element a narrowing records in place rather than replacing it, so the slot is still
    # non-nil: the narrowing stays, floored to `String`. Dropping it read `h[:name]` back as the declared `String?` and
    # reported a nil receiver on the next call.
    it "keeps a slot's non-nil proof when a String mutator rewrites the element" do
      sig = { "opts.rbs" => "class Opts\n  def table: () -> Hash[Symbol, String?]\n  def default: () -> String\nend\n" }
      expect(dumped_types(<<~RUBY, sig: sig)).to eq(["String", "String?"])
        h = Opts.new.table
        h[:name] ||= Opts.new.default
        h[:name].strip!
        dump_type(h[:name])
        g = Opts.new.table
        g[:name].strip! if g[:name]
        dump_type(g[:name])
      RUBY
    end

    it "floors a pinned or refined slot to String under a String mutator" do
      expect(run("12", 'tr!("1", "x")')).to eq("x2")
      expect(dumped_types(<<~RUBY)).to eq(%w[String String])
        k = {}
        k[:a] ||= +"x"
        k[:a].upcase!
        dump_type(k[:a])
        m = {}
        m[:n] ||= 12.to_s
        m[:n].tr!("1", "x")
        dump_type(m[:n])
      RUBY
      expect(flow_rules(<<~RUBY)).to be_empty
        k = {}
        k[:a] ||= +"x"
        k[:a].upcase!
        puts "same" if k[:a] == "x"
      RUBY
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        k = {}
        k[:a] ||= +"x"
        k[:a].upcase
        puts "same" if k[:a] == "x"
      RUBY
    end
  end

  # ADR-56's callee and escaping-closure floors count a content mutation by name. They counted the Array and Hash adders
  # only, so a String mutator made by a callee or an escaping closure left the caller's literal pinned.
  describe "the callee and escaping-closure floors" do
    it "floors a literal a callee mutates, and keeps one a callee only reads" do
      expect(dumped_types(<<~RUBY)).to eq(["String", '"ab"'])
        def strip_a(s) = s.delete_prefix!("a")
        def peek_a(s) = s.delete_prefix("a")
        b = +"ab"
        strip_a(b)
        dump_type(b)
        c = +"ab"
        peek_a(c)
        dump_type(c)
      RUBY
    end

    it "floors a literal an escaping closure mutates, and keeps one a closure only reads" do
      expect(dumped_types(<<~RUBY)).to eq(["String", '"ab"'])
        x = +"ab"
        strip = -> { x.upcase! }
        strip.call
        dump_type(x)
        y = +"ab"
        peek = -> { y.upcase }
        peek.call
        dump_type(y)
      RUBY
    end
  end

  # Issue #936: an empty-witness refinement keeps its witness only under a mutator that cannot empty the receiver.
  describe "the non-empty-string refinement" do
    let(:sig) do
      {
        "label.rbs" => <<~RBS
          class Label
            %a{rigor:v1:return: non-empty-string}
            def text: () -> String
            def plain: () -> String
          end
        RBS
      }
    end

    # The class is declared in RBS alone: the refinement comes from the `%a{}` return override, and a Ruby body
    # returning a literal would only add an unrelated diagnostic to the list these examples compare exactly.
    def label(body)
      "s = Label.new.text\n#{body}"
    end

    # Each call empties a non-empty buffer at runtime. `tr!` and `tr_s!` were listed as mutators but not as emptying,
    # so they kept the witness of a string they had just emptied.
    [
      ["a", 'delete_prefix!("a")'],
      ["a", 'delete_suffix!("a")'],
      ["a", 'bytesplice(0, 1, "")'],
      ["a", 'tr!("a", "")'],
      ["a", 'tr_s!("a", "")'],
      ["\xFF", 'encode!("UTF-8", "BINARY", invalid: :replace, undef: :replace, replace: "")'],
      ["\xFF", 'scrub!("")']
    ].each do |literal, call|
      it "retracts the witness under `#{call}`, which can empty the buffer" do
        expect(run(literal, call)).to be_empty
        expect(dumped_types(label("s.#{call}\ndump_type(s)"), sig: sig)).to eq(["String"])
        expect(flow_rules(label(%(s.#{call}\nputs "none" if s.size == 0)), sig: sig)).to be_empty
      end
    end

    # Each appends, or rewrites the buffer without being able to shorten it to nothing. `squeeze!` keeps one character
    # of every run it squeezes.
    ["setbyte(0, 98)", 'append_as_bytes("c")', "unicode_normalize!(:nfd)", 'force_encoding("BINARY")',
     "squeeze!"].each do |call|
      it "keeps the witness under `#{call}`, which cannot empty the buffer" do
        expect(dumped_types(label("s.#{call}\ndump_type(s)"), sig: sig)).to eq(["non-empty-string"])
      end
    end

    # `tr!` / `tr_s!` map every matched character to one character of the replacement, so only an empty replacement
    # empties the buffer, and the witness turns on whether the second argument is provably a non-empty String.
    it "keeps the witness under a translator whose replacement is provably non-empty" do
      expect(run("a", 'tr!("a", "_")')).to eq("_")
      expect(run("aa", 'tr_s!("a", "_")')).to eq("_")
      expect(dumped_types(label(%(s.tr!("-", "_")\ndump_type(s))), sig: sig)).to eq(["non-empty-string"])
      expect(dumped_types(label(%(s.tr_s!("-", Label.new.text)\ndump_type(s))), sig: sig)).to eq(["non-empty-string"])
    end

    it "retracts the witness under a translator whose replacement may be empty" do
      expect(dumped_types(label(%(s.tr!("-", Label.new.plain)\ndump_type(s))), sig: sig)).to eq(["String"])
    end

    it "keeps the witness, and the genuine fold, under a non-mutating call" do
      expect(dumped_types(label("s.bytesize\ndump_type(s)"), sig: sig)).to eq(["non-empty-string"])
      expect(flow_rules(label(%(s.bytesize\nputs "none" if s.size == 0)), sig: sig))
        .to eq(["flow.always-truthy-condition"])
    end
  end

  # The drift guard. The table is hand-written, and every seam above reads it, so a mutator missing from it is missing
  # everywhere at once.
  describe "the mutator table" do
    let(:mutators) { Rigor::Inference::StringMutation::MUTATORS }
    let(:bang_methods) { String.public_instance_methods(false).grep(/!\z/) }

    # Every bang method String defines rewrites the receiver in place, so none is exempt.
    it "lists every bang method String defines" do
      expect(bang_methods - mutators.to_a).to be_empty
    end

    # An oracle that needs no list of names: every public String method is called on a frozen receiver under a handful
    # of argument shapes, and the ones that raise `FrozenError` are the receiver mutators. A mutator Ruby adds without a
    # `!` (as 3.4 added `append_as_bytes`) shows up here unprompted. The invalid-byte receiver is for `scrub!`, which
    # checks for frozenness only when it has something to replace.
    it "lists exactly the methods that refuse a frozen receiver" do
      argument_shapes = [[], ["a"], [0], %w[a b], [0, "a"], [0, 1], [0, 1, "a"], [:nfd]]
      refusing = String.public_instance_methods(false).select do |name|
        ["ab", "a\xFF"].any? do |receiver|
          argument_shapes.any? do |arguments|
            receiver.dup.freeze.public_send(name, *arguments) { "" }
            false
          rescue FrozenError
            true
          rescue StandardError, NotImplementedError
            false
          end
        end
      end

      expect(refusing).to match_array(mutators.to_a)
    end

    # `data/builtins/ruby_core/string.yml` tags a C body that checks `rb_check_frozen` as `c_effects: mutate`: an
    # independent reading of the same surface, from CRuby's source rather than from method names. It misses a body
    # that modifies through a helper (`setbyte`, `clear`, `append_as_bytes`), so it is a floor under the table, not the
    # table. Three names it tags are not value mutations of a live receiver: `initialize` and `initialize_copy` run only
    # on an object `new` / `dup` is still building, and `freeze` changes no content.
    it "lists every method the builtin catalogue saw check its receiver for frozenness" do
      path = File.expand_path("../../../data/builtins/ruby_core/string.yml", __dir__)
      methods = YAML.safe_load_file(path, permitted_classes: [Symbol]).dig("classes", "String", "instance_methods")
      tagged = methods.select { |_, entry| Array(entry["c_effects"]).include?("mutate") }.keys

      expect(tagged - %w[initialize initialize_copy freeze] - mutators.map(&:to_s)).to be_empty
    end

    # A fold runs the method on the pinned value to compute the call's result, which a mutator must not do.
    it "keeps every mutator out of constant folding" do
      catalog = Rigor::Inference::Builtins::STRING_CATALOG

      expect(mutators.select { |name| catalog.safe_for_folding?("String", name) }).to be_empty
    end

    it "counts as empty-preserving only names the table lists" do
      expect(Rigor::Inference::StringMutation::EMPTY_PRESERVING - mutators).to be_empty
    end

    # ADR-103 WD3: the effect classifier and the catalogue's `mutators: string` cite the widening's table rather
    # than keeping a list of their own, which is how `force_encoding` came to be missing from the one they kept.
    it "is the table the effect classifier and the effect catalogue read" do
      expect(Rigor::Effects::Catalog::MUTATOR_SETS.fetch("string")).to equal(mutators)

      classifier = Rigor::Effects::MutationClassifier.new(singleton: false, parameters: [], owned_locals: [])
      call = ->(name) { Prism.parse("s.#{name}(x)").value.statements.body.first }
      expect(mutators.reject { |name| classifier.mutating?(call.call(name), "String") }).to be_empty
      expect(classifier.mutating?(call.call(:delete_prefix), "String")).to be(false)
    end
  end
end
