# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — {Rigor::Inference::Narrowing::RegexMatch}. {.unconditional_capture_groups} is a function of a source
# string, and {.regex_match_predicate_scopes} of an empty `Scope` and a set of group indices: no parse, no runner. The
# predicate entries take a Prism call node and the scope in effect at it, built by indexing a snippet against
# `Scope.empty` with the subject local bound to a type (the style `unreachable_branch_spec.rb` uses).
# `narrowing_spec.rb` pins the same predicates through `Narrowing.predicate_scopes` and `case_when_scopes`; these
# examples call the entries directly, so editing `regex_match.rb` selects this spec by the mirror rule.
#
# Mutation-proved: each guard line (a `return` / `next` modifier) of `regex_match.rb` was blanked in turn and an example
# here failed, except these, which no input distinguishes:
#
# - `match_receiver_edges`'s `return nil if node.receiver.nil?`: the callers are the `=~` and `!~` operator forms, which
#   always have a receiver. Tried: `self =~ /a/` (the receiver is a `SelfNode`), `send(:=~, /a/)`, `=~(/a/)` (a syntax
#   error).
# - `refinable_operand?`'s `return true if type.nil?`: with no local operand or an unbound one, the whole-receiver
#   refinement is dropped either way (`apply_whole_receiver_refinement` finds no bound subject), and
#   `analyse_whole_regex_match_predicate` declines an unbound local on its own guard. Tried: an operand the parser
#   reads as a local with no type in the scope, a string-literal operand, and no operand.
#
# `regex_operand_from_constant`'s `return nil if name.nil?` is pinned by the recorder example: without the guard,
# `Reflection.resolve_constant_type(nil, ...)` files the read with an active ADR-46 `DependencyRecorder`, whose
# `plain_constant_path?` raises on nil. Outside a recorder the call answers nil, which the `Constant` test declines.
RSpec.describe Rigor::Inference::Narrowing::RegexMatch do
  let(:combinator) { Rigor::Type::Combinator }

  def string = combinator.nominal_of("String")
  def symbol = combinator.nominal_of("Symbol")
  def integer = combinator.nominal_of("Integer")
  def nil_type = combinator.constant_of(nil)
  def short(type) = type.nil? ? :unbound : type.describe(:short)

  # `[node, scope]` for the last statement of `source`, with each `locals` name bound to its type beforehand.
  # `declared` names the locals the parser reads as locals; it defaults to the bound ones, and a name declared but not
  # bound is a local the scope has no type for.
  def at(source, locals = {}, declared: locals.keys)
    program = Prism.parse(source, scopes: [declared]).value
    base = locals.reduce(Rigor::Scope.empty) { |scope, (name, type)| scope.with_local(name, type) }
    node = program.statements.body.last
    [node, Rigor::Inference::ScopeIndexer.index(program, default_scope: base)[node]]
  end

  # `[match, no_match]` reads of the globals `names` on a pair of edge scopes, `:unbound` where no type is recorded.
  def globals(pair, names = %i[$~ $1 $2]) = pair.map { |edge| names.map { |name| short(edge.global(name)) } }

  def groups(source) = described_class.unconditional_capture_groups(source).to_a.sort

  describe ".unconditional_capture_groups" do
    it "counts every plain group of a pattern with no quantifier or alternation" do
      expect(groups("(a)(b)")).to eq([1, 2])
      expect(groups("(x(y))")).to eq([1, 2])
      expect(groups("")).to eq([])
    end

    it "drops a group an optional quantifier applies to, with its descendants" do
      expect(groups("(a)?(b)")).to eq([2])
      expect(groups("(a)*b")).to eq([])
      expect(groups("((a)(b))?")).to eq([])
      expect(groups("(a)*?")).to eq([])
      expect(groups("(a)??")).to eq([])
      expect(groups("(a)*+")).to eq([])
    end

    it "drops a group a zero-permitting brace quantifier applies to" do
      expect(groups("(a){0,2}")).to eq([])
      expect(groups("(a){0}")).to eq([])
      expect(groups("(a){,2}")).to eq([])
    end

    it "keeps a group a `+` or a non-zero brace quantifier applies to, and braces that are literal" do
      expect(groups("(a)+")).to eq([1])
      expect(groups("(a){1,2}")).to eq([1])
      expect(groups("(a){,}")).to eq([1])
      expect(groups("(a){x}")).to eq([1])
    end

    it "drops every group of a pattern with a top-level alternation" do
      expect(groups("(a)|(b)")).to eq([])
      expect(groups("a|(b)")).to eq([])
      expect(groups("(a)|b")).to eq([])
    end

    it "keeps a group that holds an alternation but drops the groups inside its branches" do
      expect(groups("(a|b)")).to eq([1])
      expect(groups("(a|(b))")).to eq([1])
      expect(groups("((a)|b)(c)")).to eq([1, 3])
      expect(groups("(a(b|c))")).to eq([1, 2])
    end

    it "does not count groups that do not capture" do
      expect(groups("(?:x)(y)")).to eq([1])
      expect(groups("(?=(x))y")).to eq([1])
      expect(groups("(?<=x)(y)")).to eq([1])
      expect(groups("(?<!x)(y)")).to eq([1])
      expect(groups("(?i)(a)")).to eq([1])
      expect(groups("(a(?:b|c))")).to eq([1])
    end

    it "counts only the named groups once the pattern has one, with either spelling" do
      expect(groups("(?<n>a)(b)")).to eq([1])
      expect(groups("(?'n'a)(b)")).to eq([1])
      expect(groups("(?<a>x)(?<b>y)")).to eq([1, 2])
      expect(groups("(?'n'a)(b)(c)")).to eq([1])
    end

    it "does not take a plain group for a named one because of a `'` or `<` after its first character" do
      expect(groups("(a')(b)")).to eq([1, 2])
      expect(groups("(a<b)(c)")).to eq([1, 2])
    end

    it "skips an escaped paren and a paren inside a character class" do
      expect(groups("\\((x)\\)")).to eq([1])
      expect(groups("[(](x)")).to eq([1])
      expect(groups("[]x](a)")).to eq([1])
      expect(groups("[^]x](a)")).to eq([1])
      expect(groups("[a\\]b](c)")).to eq([1])
    end

    it "stops at an unterminated character class and a trailing escape" do
      expect(groups("(a)[(")).to eq([1])
      expect(groups("(a)\\")).to eq([1])
      expect(groups("[")).to eq([])
      expect(groups("[^")).to eq([])
    end
  end

  describe ".regex_match_predicate_scopes" do
    let(:scope) { Rigor::Scope.empty }

    it "binds `$~` to MatchData, the whole-match globals to String and each unconditional `$N` on the match edge" do
      pair = described_class.regex_match_predicate_scopes(scope, Set[1, 2])

      expect(globals(pair, %i[$~ $& $` $' $1 $2 $3 $+]).first)
        .to eq(["MatchData", "String", "String", "String", "String", "String", :unbound, "String"])
    end

    it "binds the same globals to nil on the no-match edge" do
      pair = described_class.regex_match_predicate_scopes(scope, Set[1, 2])

      expect(globals(pair,
                     %i[$~ $& $` $' $1 $2 $3
                        $+]).last).to eq(["nil", "nil", "nil", "nil", "nil", "nil", :unbound, "nil"])
    end

    it "leaves `$+` unbound on both edges when no group is unconditional" do
      pair = described_class.regex_match_predicate_scopes(scope, Set.new)

      expect(globals(pair, %i[$~ $1 $+])).to eq([["MatchData", :unbound, :unbound], ["nil", :unbound, :unbound]])
    end

    it "forgets the globals an earlier match bound, on both edges" do
      earlier = scope.with_global(:$3, string).with_global(:$1, string)

      pair = described_class.regex_match_predicate_scopes(earlier, Set[1])

      expect(globals(pair, %i[$1 $3])).to eq([["String", :unbound], ["nil", :unbound]])
    end
  end

  describe ".match_member_kinds" do
    let(:source) do
      "class MyStr < String\n  def =~(other) = nil\nend\nclass Sub < String\nend\nclass Mixed < Sub\nend\n" \
        "class Plain\nend\nnil"
    end

    def kinds(*types)
      described_class.match_member_kinds(types.size == 1 ? types.first : combinator.union(*types), at(source).last)
    end

    it "classifies a String, a Symbol and a value of either" do
      expect(kinds(string)).to eq([:string])
      expect(kinds(symbol)).to eq([:symbol])
      expect(kinds(combinator.constant_of("a"))).to eq([:string])
      expect(kinds(combinator.constant_of(:a))).to eq([:symbol])
    end

    it "classifies nil, as a value and as its nominal" do
      expect(kinds(nil_type)).to eq([:nil])
      expect(kinds(combinator.nominal_of("NilClass"))).to eq([:nil])
    end

    it "classifies each member of a union" do
      expect(kinds(string, symbol)).to eq(%i[string symbol])
      expect(kinds(string, nil_type)).to eq(%i[string nil])
    end

    it "classifies a project class with its own `=~` as custom, and a project subclass of String as one" do
      expect(kinds(combinator.nominal_of("MyStr"))).to eq([:custom])
      expect(kinds(combinator.nominal_of("Sub"))).to eq([:string_subclass])
      expect(kinds(combinator.nominal_of("Mixed"))).to eq([:string_subclass])
    end

    it "answers nil for a class that is neither" do
      expect(kinds(combinator.nominal_of("Plain"))).to eq([nil])
      expect(kinds(integer)).to eq([nil])
      expect(kinds(combinator.top)).to eq([nil])
      expect(kinds(combinator.tuple_of(string))).to eq([nil])
      expect(kinds(combinator.constant_of(true))).to eq([nil])
    end

    it "calls an untyped Dynamic, and a Dynamic over Strings, Symbols and nil, dynamic" do
      expect(kinds(combinator.untyped)).to eq([:dynamic])
      expect(kinds(combinator.dynamic(string))).to eq([:dynamic])
      expect(kinds(combinator.dynamic(combinator.union(string, nil_type)))).to eq([:dynamic])
    end

    it "answers nil for a Dynamic over another class" do
      expect(kinds(combinator.dynamic(integer))).to eq([nil])
    end

    it "calls Bot a String, since no class can be disproved of it" do
      expect(kinds(combinator.bot)).to eq([:string])
    end
  end

  describe ".analyse_regex_match_predicate" do
    def match(source, locals = { s: string }) = described_class.analyse_regex_match_predicate(*at(source, locals))

    it "binds the match globals on the match edge and nil on the no-match edge, for either operand order" do
      expect(globals(match("s =~ /(a)/"))).to eq([["MatchData", "String", :unbound], ["nil", "nil", :unbound]])
      expect(globals(match("/(a)/ =~ s"))).to eq([["MatchData", "String", :unbound], ["nil", "nil", :unbound]])
    end

    it "binds only the unconditional groups" do
      expect(globals(match("s =~ /(a)(b)?/"))).to eq([["MatchData", "String", :unbound], ["nil", "nil", :unbound]])
      expect(globals(match("s =~ /(a)(b)/"))).to eq([%w[MatchData String String], %w[nil nil nil]])
    end

    it "declines a call with no argument or two arguments" do
      expect(match("s.=~")).to be_nil
      expect(match("s.=~(/a/, /b/)")).to be_nil
    end

    it "declines when neither operand, or both, is a regex" do
      expect(match("s =~ 1")).to be_nil
      expect(match('s =~ "(a)"')).to be_nil
      expect(match("/a/ =~ /b/", {})).to be_nil
    end

    it "declines an extended-mode pattern, which the group walk would miscount" do
      expect(match("s =~ /(a) # (\n(b)/x")).to be_nil
    end

    it "keeps the whole-match globals for a pattern with no group" do
      expect(globals(match("s =~ /a/"),
                     %i[$~ $& $1])).to eq([["MatchData", "String", :unbound], ["nil", "nil", :unbound]])
    end

    it "keeps both edges for a String, a Symbol, a String constant and a Regexp on the left of any receiver" do
      [string, symbol, combinator.constant_of("abc")].each do |type|
        expect(globals(match("s =~ /(a)/", { s: type }), %i[$~])).to eq([["MatchData"], ["nil"]])
      end
      expect(globals(match("/(a)/ =~ s", { s: integer }), %i[$~])).to eq([["MatchData"], ["nil"]])
      expect(globals(match("/(a)/ =~ s", { s: nil_type }), %i[$~])).to eq([["MatchData"], ["nil"]])
    end

    it "keeps the match edge only for a nilable, untyped or non-String receiver" do
      [combinator.union(string, nil_type), combinator.untyped, integer,
       combinator.union(string, integer)].each do |type|
        expect(globals(match("s =~ /(a)/", { s: type }),
                       %i[$~ $1])).to eq([%w[MatchData String], %i[unbound unbound]])
      end
    end

    it "keeps the match edge only for a safe-navigation call, whatever the receiver" do
      expect(globals(match("s&.=~(/(a)/)"), %i[$~])).to eq([["MatchData"], [:unbound]])
    end

    it "keeps neither edge for a receiver with a `=~` of its own" do
      source = "class MyStr < String\n  def =~(other) = nil\nend\ns =~ /(a)/"

      expect(globals(match(source, { s: combinator.nominal_of("MyStr") }), %i[$~])).to eq([[:unbound], [:unbound]])
    end

    it "keeps both edges for a project subclass of String" do
      source = "class Sub < String\nend\ns =~ /(a)/"

      expect(globals(match(source, { s: combinator.nominal_of("Sub") }), %i[$~])).to eq([["MatchData"], ["nil"]])
    end

    context "with a constant pattern" do
      it "reads a Regexp constant, plain or qualified or rooted" do
        ["RE = /(a)/\ns =~ RE", "module Foo\n  RE = /(a)/\nend\ns =~ Foo::RE", "RE = /(a)/\ns =~ ::RE",
         "RE = /(a)/\nRE =~ s", "RE = Regexp.new(\"(a)\")\ns =~ RE"].each do |source|
          expect(globals(match(source), %i[$~ $1])).to eq([%w[MatchData String], %w[nil nil]])
        end
      end

      it "declines an unknown, a non-Regexp, an extended, a twice-assigned and an opaque constant" do
        ["s =~ RE", "RE = \"(a)\"\ns =~ RE", "RE = /(a) # (\n(b)/x\ns =~ RE", "RE = /(a)/\nRE = /(b)(c)/\ns =~ RE",
         "RE = Object.new\ns =~ RE"].each do |source|
          expect(match(source)).to be_nil
        end
      end

      it "declines a regex literal beside a regex constant, which leaves no string subject" do
        expect(match("RE = /(a)/\nRE =~ /b/")).to be_nil
        expect(match("RE = /(a)/\nRE =~ RE")).to be_nil
      end

      it "declines a twice-assigned constant beside a regex literal, which is ambiguous, not absent" do
        expect(match("RE = /(a)/\nRE = /(b)(c)/\nRE =~ /(d)/")).to be_nil
      end

      it "declines a constant path whose parent is not a constant while a dependency recorder is active (ADR-46)" do
        # `Reflection.resolve_constant_type(nil, ...)` files a read of the name with the recorder, which raises on nil.
        result = Rigor::Analysis::DependencyRecorder.record_for("lib/x.rb") do
          match("s =~ foo::RE", { s: string, foo: string })
        end

        expect(result).to be_a(Rigor::Analysis::DependencyRecorder::Record)
      end

      it "declines a constant path whose parent is not a constant" do
        expect(match("s =~ foo::RE", { s: string, foo: string })).to be_nil
      end
    end

    context "with an anchored pattern (#164)" do
      def refined(source, type) = short(match(source, { s: type }).first.local(:s))

      it "narrows the string operand on the match edge to the refinement the pattern names" do
        expect(refined("s =~ /\\A\\d+\\z/", string)).to eq("decimal-int-string")
        expect(refined("/\\A\\d+\\z/ =~ s", string)).to eq("decimal-int-string")
        expect(refined("s =~ /\\A\\d+\\z/", combinator.constant_of("5"))).to eq("decimal-int-string")
      end

      it "keeps the no-match edge's operand as it was" do
        expect(short(match("s =~ /\\A\\d+\\z/").last.local(:s))).to eq("String")
      end

      it "narrows a nilable String operand, whose nil the match edge excludes" do
        expect(refined("s =~ /\\A\\d+\\z/", combinator.union(string, nil_type))).to eq("decimal-int-string")
      end

      it "leaves a Symbol, an untyped, an Integer and a mixed operand as they are" do
        expect(refined("s =~ /\\A\\d+\\z/", symbol)).to eq("Symbol")
        expect(refined("s =~ /\\A\\d+\\z/", combinator.untyped)).to eq("Dynamic[top]")
        expect(refined("s =~ /\\A\\d+\\z/", integer)).to eq("Integer")
        expect(refined("s =~ /\\A\\d+\\z/", combinator.union(string, integer))).to eq("Integer | String")
      end

      it "leaves a pattern the refinement table does not know alone" do
        expect(refined("s =~ /\\d+/", string)).to eq("String")
      end

      it "narrows nothing when the operand is not a local the scope binds" do
        pair = match("1 =~ /\\A\\d+\\z/", {})

        expect(pair.first.local(:s)).to be_nil
        expect(match("s =~ /\\A\\d+\\z/", {}).first.local(:s)).to be_nil
      end
    end
  end

  describe ".analyse_regex_not_match_predicate" do
    def not_match(source, locals = { s: string })
      described_class.analyse_regex_not_match_predicate(*at(source, locals))
    end

    it "swaps the edges of `=~`" do
      expect(globals(not_match("s !~ /(a)/"))).to eq([["nil", "nil", :unbound], ["MatchData", "String", :unbound]])
    end

    it "keeps both edges for a Symbol receiver, and the falsey edge only for a nilable or untyped one" do
      expect(globals(not_match("s !~ /(a)/", { s: symbol }), %i[$~])).to eq([["nil"], ["MatchData"]])
      expect(globals(not_match("s !~ /(a)/", { s: combinator.union(string, nil_type) }), %i[$~]))
        .to eq([[:unbound], ["MatchData"]])
      expect(globals(not_match("s !~ /(a)/", { s: combinator.untyped }), %i[$~])).to eq([[:unbound], ["MatchData"]])
    end

    it "keeps neither edge for a receiver that is not a String, a Symbol, nil or untyped" do
      expect(globals(not_match("s !~ /(a)/", { s: integer }), %i[$~])).to eq([[:unbound], [:unbound]])
      expect(globals(not_match("s !~ /(a)/", { s: combinator.union(string, integer) }), %i[$~]))
        .to eq([[:unbound], [:unbound]])
    end

    it "keeps neither edge for a safe-navigation call" do
      expect(globals(not_match("s&.!~(/(a)/)"), %i[$~])).to eq([[:unbound], [:unbound]])
    end

    it "keeps neither edge for a receiver with a `=~` of its own" do
      source = "class MyStr < String\n  def =~(other) = nil\nend\ns !~ /(a)/"

      expect(globals(not_match(source, { s: combinator.nominal_of("MyStr") }), %i[$~])).to eq([[:unbound], [:unbound]])
    end

    it "declines what `=~` declines" do
      expect(not_match("s !~ 1")).to be_nil
      expect(not_match("s !~ /(a) # (\n(b)/x")).to be_nil
    end
  end

  describe ".analyse_whole_regex_match_predicate" do
    def whole(source, locals = { s: string }) = described_class.analyse_whole_regex_match_predicate(*at(source, locals))

    it "narrows the receiver local to the refinement on the truthy edge only" do
      pair = whole("s.match?(/\\A\\d+\\z/)")

      expect(pair.map { |edge| short(edge.local(:s)) }).to eq(%w[decimal-int-string String])
    end

    it "narrows a nilable String, whose nil the match excludes" do
      pair = whole("s.match?(/\\A\\d+\\z/)", { s: combinator.union(string, nil_type) })

      expect(pair.map { |edge| short(edge.local(:s)) }).to eq(%w[decimal-int-string String?])
    end

    it "declines a receiver that may be a Symbol or is untyped" do
      expect(whole("s.match?(/\\A\\d+\\z/)", { s: symbol })).to be_nil
      expect(whole("s.match?(/\\A\\d+\\z/)", { s: combinator.untyped })).to be_nil
    end

    it "declines a receiver that is not a local" do
      expect(whole("s.t.match?(/\\A\\d+\\z/)")).to be_nil
      expect(whole("@s.match?(/\\A\\d+\\z/)")).to be_nil
    end

    it "declines a call whose name is a bound local, which is not a read of it" do
      expect(whole("self.t.match?(/\\A\\d+\\z/)", { t: string })).to be_nil
    end

    it "declines a local the scope binds no type for" do
      expect(described_class.analyse_whole_regex_match_predicate(*at("s.match?(/\\A\\d+\\z/)", {}, declared: [:s])))
        .to be_nil
    end

    it "declines no argument, two arguments, an argument that is not a regex and an extended regex" do
      expect(whole("s.match?")).to be_nil
      expect(whole("s.match?(/\\A\\d+\\z/, 1)")).to be_nil
      expect(whole("s.match?(t)", { s: string, t: string })).to be_nil
      expect(whole("s.match?(/\\A\\d+\\z/x)")).to be_nil
    end

    it "declines a pattern the refinement table does not know" do
      expect(whole("s.match?(/\\d+/)")).to be_nil
    end

    it "reads a constant pattern" do
      pair = whole("RE = /\\A\\d+\\z/\ns.match?(RE)")

      expect(pair.map { |edge| short(edge.local(:s)) }).to eq(%w[decimal-int-string String])
    end
  end
end
