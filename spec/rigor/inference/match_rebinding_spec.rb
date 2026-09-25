# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1358 — Ruby keeps the regex match globals in the method frame's special-variable slot, and every block and
# closure made in the method reaches that same slot, while a `def`, class or module body has a slot of its own.
RSpec.describe Rigor::Inference::MatchRebinding do
  # `WORD_RE` resolves to a Regexp, `KEYS` to a tuple of Strings and `LIMITS` to a Hash; any other constant does not
  # resolve.
  let(:scope) do
    bare = Rigor::Scope.empty(environment: Rigor::Environment.default)
    combinator = Rigor::Type::Combinator
    constants = {
      "WORD_RE" => combinator.constant_of(/(\w)!/),
      "KEYS" => combinator.tuple_of(combinator.constant_of("a"), combinator.constant_of("b")),
      "LIMITS" => combinator.nominal_of(
        "Hash", type_args: [combinator.nominal_of("Symbol"), combinator.nominal_of("Integer")]
      )
    }
    bare.with_discovery(bare.discovery.with(in_source_constants: constants))
  end

  def last_statement(source) = Prism.parse(source).value.statements.body.last
  def root(source) = Prism.parse(source).value
  def may_match?(source) = described_class.may_match?(last_statement(source), scope)

  describe ".may_match?" do
    it "counts a call that rebinds `$~` whatever its argument, in a nested block or lambda too" do
      expect(may_match?("items.each { |i| i =~ /(z)/ }")).to be(true)
      expect(may_match?("items.each { |i| i.sub('a', '') }")).to be(true)
      expect(may_match?("items.each { -> { s.scan('q') } }")).to be(true)
    end

    # `h[k]`, `s.split(":")` and `s.index(x)` are lookups far more often than matches, and counting them dropped the
    # narrowing on correct code.
    it "counts `[]`, `split`, `index` and their kin only with an argument known to be a Regexp" do
      expect(may_match?("fields.each { |f| out[f] = row[f] }")).to be(false)
      expect(may_match?("parts.each { |p| p.split(':') }")).to be(false)
      expect(may_match?("parts.each { |p| p[0, 2]; p.index(sep) }")).to be(false)
      expect(may_match?("parts.each { |p| p[/(z)/] }")).to be(true)
      expect(may_match?("parts.each { |p| p.split(Regexp.new(sep)) }")).to be(true)
      expect(may_match?("parts.each { |p| p.index(WORD_RE) }")).to be(true)
    end

    # A local or instance variable bound to a Regexp where the block is written; a block parameter is not bound
    # there.
    it "counts a lookup argument bound to a Regexp outside the block" do
      regexp = Rigor::Type::Combinator.constant_of(/(q)/)
      string = Rigor::Type::Combinator.nominal_of("String")
      read = last_statement("re = nil; items.each { |i| i[re] }")

      expect(described_class.may_match?(read, scope.with_local(:re, regexp))).to be(true)
      expect(described_class.may_match?(read, scope.with_local(:re, string))).to be(false)
      expect(described_class.may_match?(last_statement("items.each { |i| i.index(@re) }"),
                                        scope.with_ivar(:@re, Rigor::Type::Combinator.nominal_of("Regexp"))))
        .to be(true)
    end

    it "counts `grep` / `grep_v` only in their block form" do
      expect(may_match?("groups.each { |g| g.grep(/(z)/) }")).to be(false)
      expect(may_match?("groups.each { |g| g.grep(/(z)/) { |x| x } }")).to be(true)
      expect(may_match?("groups.each { |g| g.grep_v(/(z)/, &handler) }")).to be(true)
    end

    it "does not count `match?`, which never sets `$~`" do
      expect(may_match?("items.each { |i| i.match?(/(z)/) }")).to be(false)
    end

    it "counts `===` on a receiver that may be a Regexp, not one that resolves to a class" do
      expect(may_match?("items.each { |i| re === i }")).to be(true)
      expect(may_match?("items.each { |i| String === i }")).to be(false)
    end

    it "counts a `when` condition that may be a Regexp: a regex literal, a Regexp constant, or an expression" do
      expect(may_match?("case i when /(z)/ then 1 end")).to be(true)
      expect(may_match?("case i when WORD_RE then 1 end")).to be(true)
      expect(may_match?("case i when re then 1 end")).to be(true)
      expect(may_match?("case i when *res then 1 end")).to be(true)
    end

    it "does not count a `when` condition that is a non-Regexp literal, a class, a collection or unresolved" do
      expect(may_match?("case i when String, 'q', :s, 1..2, nil then 1 end")).to be(false)
      expect(may_match?("case i when KEYS, LIMITS then 1 end")).to be(false)
      expect(may_match?("case i when *KEYS then 1 end")).to be(false)
      expect(may_match?("case i when Some::Unknown::Klass, Unknown then 1 end")).to be(false)
    end

    it "does not count the conditions of a `case` without a subject, which run no `===`" do
      expect(may_match?("items.each { |i| case; when i.empty? then 1; end }")).to be(false)
      expect(may_match?("items.each { |i| case; when re then 1; end }")).to be(false)
      expect(may_match?("items.each { |i| case; when i =~ /(z)/ then 1; end }")).to be(true)
    end

    it "counts an `in` / `=>` pattern holding a value that may be a Regexp" do
      expect(may_match?("case i; in [/(z)/] then 1; else 2; end")).to be(true)
      expect(may_match?("i in WORD_RE")).to be(true)
      expect(may_match?("re = nil; i in ^re")).to be(true)
    end

    it "does not count a pattern's structure, classes, unresolved constants or guard" do
      expect(may_match?("i in [Integer, String] | { name: String } | nil")).to be(false)
      expect(may_match?("i => [x, *rest]")).to be(false)
      expect(may_match?("i in Some::Unknown::Klass")).to be(false)
      expect(may_match?("case i; in { k: v } if LIMITS.key?(v) then 1; else 2; end")).to be(false)
      expect(may_match?("case i; in { k: v } unless v then 1; else 2; end")).to be(false)
      expect(may_match?("case i; in { k: v } if v.match?(/\\A[a-z]\\z/) then 1; else 2; end")).to be(false)
      expect(may_match?("case i; in { k: v } if v =~ /(z)/ then 1; else 2; end")).to be(true)
    end

    it "counts a bare regex condition and a write to `$~`" do
      expect(may_match?("1 if /(z)/")).to be(true)
      expect(may_match?("items.each { |m| $~ = m }")).to be(true)
      expect(may_match?("items.each { |m| $x = m }")).to be(false)
    end

    it "does not count a `def`, class or module body, or a `defined?` operand" do
      expect(may_match?("items.each { def m(x) = x =~ /(z)/ }")).to be(false)
      expect(may_match?("items.each { module M; X = 'a' =~ /(z)/; end }")).to be(false)
      expect(may_match?("defined?(x =~ /(z)/)")).to be(false)
    end

    it "does not count a call whose name cannot match, such as an implicit-self one" do
      expect(may_match?("items.each { |i| puts i.upcase }")).to be(false)
    end

    # Issue #1364 — `!~` runs `=~`, and these builtins set `$~` when given a Regexp.
    it "counts `!~`, and `start_with?`, `byteindex`, `byterindex` and the pattern predicates with a Regexp" do
      expect(may_match?("items.each { |l| l !~ /(z)/ }")).to be(true)
      expect(may_match?("items.each { |l| l.start_with?(/(z)/) }")).to be(true)
      expect(may_match?("items.each { |l| l.byteindex(WORD_RE) }")).to be(true)
      expect(may_match?("items.each { |l| [l].any?(/(z)/) }")).to be(true)
      expect(may_match?("items.each { |l| l.start_with?('#') }")).to be(false)
    end

    # A `yield`, and a call into a Ruby method, rebind this frame only through a C-function proc or code the scan does
    # not read; neither counts, so a block that yields keeps the narrowing as before #1364.
    it "does not count a `yield`, `eval`, or a call on the method's own block" do
      expect(may_match?("items.each { |i| yield i }")).to be(false)
      expect(may_match?("sources.each { |src| eval(src) }")).to be(false)
      expect(may_match?("items.each { |i| blk.call(i) }")).to be(false)
    end
  end

  describe ".block_may_match?" do
    def block_may_match?(source, in_scope = scope) = described_class.block_may_match?(last_statement(source), in_scope)

    it "answers for a block literal by its body" do
      expect(block_may_match?("items.each { |i| i =~ /(z)/ }")).to be(true)
      expect(block_may_match?("items.each { |i| puts i }")).to be(false)
    end

    it "counts a `&expr` block argument, which may be a proc made in this frame" do
      expect(block_may_match?("items.each(&handler)")).to be(true)
      expect(block_may_match?("items.each(&method(:m))")).to be(true)
    end

    it "counts a Symbol block argument only for a method that rebinds `$~`" do
      expect(block_may_match?("items.each(&:freeze)")).to be(false)
      expect(block_may_match?("items.inject(&:=~)")).to be(true)
      expect(block_may_match?("items.inject(&:!~)")).to be(true)
      expect(block_may_match?("items.inject(&:[])")).to be(false)
    end

    it "does not count an anonymous `&`, or a call without a block" do
      forwarding = last_statement("def m(&) = items.each(&)").body.body.first

      expect(described_class.block_may_match?(forwarding, scope)).to be(false)
      expect(block_may_match?("items.first")).to be(false)
    end

    context "with the method's own `&block` parameter" do
      def forwarded_may_match?(source)
        def_node = last_statement(source)
        framed = scope.with_match_frame(def_node.body, def_node.parameters)
        call = def_node.body.breadth_first_search do |node|
          node.is_a?(Prism::CallNode) && node.name == :each && node.block.is_a?(Prism::BlockArgumentNode)
        end
        described_class.block_may_match?(call, framed)
      end

      it "does not count it, since it forwards the block the caller made" do
        expect(forwarded_may_match?("def m(env, &blk); env.each(&blk); end")).to be(false)
      end

      it "counts it once the body rebinds or shadows the name" do
        expect(forwarded_may_match?("def m(env, &blk); blk = proc { |x| x =~ /(q)/ }; env.each(&blk); end")).to be(true)
        expect(forwarded_may_match?("def m(procs, env, &blk); procs.each { |blk| env.each(&blk) }; end")).to be(true)
      end
    end
  end

  # Issue #1364 — a method defined in Ruby runs in a frame of its own, so an implicit-self call rebinds the caller's
  # `$~` only as a builtin or eval that matches on its behalf.
  describe Rigor::Inference::MatchRebinding::SelfCalls do
    def named_match?(source) = described_class.named_match?(last_statement(source))

    it "does not count a call into a Ruby method" do
      expect(named_match?('log("parsed")')).to be(false)
      expect(named_match?('warn "debug"')).to be(false)
      expect(named_match?('self.log("x")')).to be(false)
    end

    it "counts `eval`, and `instance_eval` / `class_eval` / `module_eval` in their String form, on any receiver" do
      expect(named_match?("eval(src)")).to be(true)
      expect(named_match?("Kernel.eval(src)")).to be(true)
      expect(named_match?("instance_eval(src)")).to be(true)
      expect(named_match?("klass.class_eval(src, __FILE__)")).to be(true)
      expect(named_match?("instance_eval { |x| x }")).to be(false)
    end

    it "counts a `send` whose name is not a literal, or names a method that counts" do
      expect(named_match?("send(name, s)")).to be(true)
      expect(named_match?("u.__send__(:=~, /(q)/)")).to be(true)
      expect(named_match?("public_send('eval', src)")).to be(true)
      expect(named_match?("send(:log, s)")).to be(false)
    end

    # An invalid byte cannot become a Symbol; the name compares as a String and does not count.
    it "reads a literal name with an invalid byte without raising" do
      expect(named_match?('send("\xff", 1)')).to be(false)
      expect(described_class.method_name_literal?(last_statement('log("\xff")').arguments.arguments.first))
        .to be(false)
    end

    it "counts the builtins that set their caller's `$~`, the predicates only with a pattern" do
      expect(named_match?("u !~ /(z)/")).to be(true)
      expect(named_match?("start_with?(/(z)/)")).to be(true)
      expect(named_match?("[u].any?(/(z)/)")).to be(true)
      expect(named_match?("any?")).to be(false)
    end

    it "counts `send(:binding)` or a computed `send` as one that may hand out the frame" do
      expect(described_class.sends_binding?(last_statement("send(:binding)"))).to be(true)
      expect(described_class.sends_binding?(last_statement("send(name)"))).to be(true)
      expect(described_class.sends_binding?(last_statement("send(:log)"))).to be(false)
    end
  end

  # Issue #1364 — an implicit-self call no longer forgets by itself, so it answers for the match its own arguments may
  # run, which applies no reset of its own (#1365).
  describe ".operand_may_match?" do
    def operand_may_match?(source) = described_class.operand_may_match?(last_statement(source).arguments, scope)

    it "counts a call the table or {SelfCalls} counts on any receiver, a literal naming one, or a `yield`" do
      expect(operand_may_match?('log(line.sub(/=/, ": "))')).to be(true)
      expect(operand_may_match?("log(\"\#{h[k]}\")")).to be(true)
      expect(operand_may_match?("log(u !~ /(z)/)")).to be(true)
      expect(operand_may_match?("log(u.start_with?(/(z)/))")).to be(true)
      expect(operand_may_match?("log(Kernel.eval(src))")).to be(true)
      expect(operand_may_match?("log(u.send(:=~, /(q)/))")).to be(true)
      expect(operand_may_match?("inject(:=~)")).to be(true)
      expect(operand_may_match?("log(yield)")).to be(true)
      expect(operand_may_match?("log(case s when /(z)/ then 1 end)")).to be(true)
    end

    it "does not count an argument that only reads, or a block or lambda the other rules answer for" do
      expect(operand_may_match?("log(\"\#{$2.strip}: parsed\")")).to be(false)
      expect(operand_may_match?("log(items.map { |i| i =~ /(z)/ })")).to be(false)
      expect(operand_may_match?("register(-> { s =~ /(z)/ })")).to be(false)
    end
  end

  # Issue #1364 — where the frame hands its slot to code the analyzer does not trace, an implicit-self call forgets as
  # every one did before.
  describe ".self_call_fallback?" do
    def fallback?(source, block_name = nil) = described_class.self_call_fallback?(root(source), block_name, scope)

    def forward?(source, block_name = nil)
      described_class.self_call_fallback?(last_statement(source).body, block_name, scope)
    end

    it "counts a block literal that may match, whatever it is handed to" do
      expect(fallback?("on { |l| l =~ /(z)/ }")).to be(true)
      expect(fallback?("lines.map! { |l| l.sub(/ +$/, '') }")).to be(true)
      expect(fallback?("super { |l| l =~ /(z)/ }")).to be(true)
      expect(fallback?("items.each { |i| puts i }")).to be(false)
      expect(fallback?("def m = on { |l| l =~ /(z)/ }")).to be(false)
    end

    # The broad reading counts a lookup with any argument but a non-Regexp literal, a block parameter included,
    # where the block scan does not.
    it "reads the block broadly" do
      source = "on { |l, pattern| l.index(pattern) }"

      expect(fallback?(source)).to be(true)
      expect(described_class.may_match?(last_statement(source).block.body, scope)).to be(false)
      expect(fallback?("on { |l| l.index('x') }")).to be(false)
    end

    it "counts `binding` in any spelling" do
      expect(fallback?("eval_in(binding)")).to be(true)
      expect(fallback?("eval_in(proc {}.binding)")).to be(true)
      expect(fallback?("eval_in(send(:binding))")).to be(true)
    end

    it "counts a forward of the method's own block, anonymous or named, or of `...`" do
      expect(forward?("def m(&blk) = instance_exec(1, &blk)", :blk)).to be(true)
      expect(forward?("def m(&) = each(&)")).to be(true)
      expect(forward?("def m(...) = f(...)")).to be(true)
      expect(forward?("def m(other, &blk) = instance_exec(1, &other)", :blk)).to be(false)
      expect(fallback?("def m(&) = each(&)")).to be(false)
    end

    it "answers for a method's parameter defaults on the frame" do
      def_node = last_statement("def m(s, f = on { |l| l =~ /(z)/ }) = log(s)")

      expect(Rigor::Inference::MatchRebinding::Frame.new(def_node.body, def_node.parameters).self_call_fallback?(scope))
        .to be(true)
      expect(Rigor::Inference::MatchRebinding::Frame.new(def_node.body).self_call_fallback?(scope)).to be(false)
    end
  end

  describe ".call_may_match?" do
    def call_may_match?(source) = described_class.call_may_match?(last_statement(source), scope)

    it "counts a block that runs in the receiver chain or an argument" do
      expect(call_may_match?("items.select { |i| i =~ /(z)/ }.map(&:upcase)")).to be(true)
      expect(call_may_match?("log(items.map { |i| i =~ /(z)/ })")).to be(true)
      expect(call_may_match?("log(items.map(&handler))")).to be(true)
    end

    it "does not count a lambda there, which does not run yet, or a call without a block" do
      expect(call_may_match?("register(-> { s =~ /(z)/ })")).to be(false)
      expect(call_may_match?("log(s.sub(/(z)/, ''))")).to be(false)
      expect(call_may_match?("items.select { |i| i.empty? }.map(&:upcase)")).to be(false)
    end
  end

  describe ".matching_closure?" do
    def matching_closure?(source) = described_class.matching_closure?(root(source), scope)

    it "counts a lambda literal, or a block a call keeps to run later, whose body may match" do
      expect(matching_closure?("f = -> { s =~ /(z)/ }")).to be(true)
      expect(matching_closure?("f = lambda { s =~ /(z)/ }")).to be(true)
      expect(matching_closure?("f = Proc.new { s =~ /(z)/ }")).to be(true)
      expect(matching_closure?("fs = items.map { |i| -> { i =~ /(z)/ } }")).to be(true)
      expect(matching_closure?("register(-> { s =~ /(z)/ })")).to be(true)
    end

    it "does not count a closure that cannot match, a block the call runs now, or a nested `def`'s closure" do
      expect(matching_closure?("f = -> { s.upcase }")).to be(false)
      expect(matching_closure?("lookup = ->(k) { h[k] }")).to be(false)
      expect(matching_closure?("items.each { |i| i =~ /(z)/ }")).to be(false)
      expect(matching_closure?("def m = -> { s =~ /(z)/ }")).to be(false)
    end

    it "counts a closure in a method's parameter defaults, which run in the method's frame" do
      def_node = last_statement('def m(s, f = -> { "zz" =~ /(q)/ }) = f.call')

      expect(Rigor::Inference::MatchRebinding::Frame.new(def_node.body, def_node.parameters).matching_closure?(scope))
        .to be(true)
      expect(Rigor::Inference::MatchRebinding::Frame.new(def_node.body).matching_closure?(scope)).to be(false)
    end
  end

  describe ".block_entry" do
    let(:string) { Rigor::Type::Combinator.nominal_of("String") }
    let(:narrowed) { scope.with_global(:$1, string) }

    def block(source) = last_statement(source).block

    it "forgets the match globals for a body that may match, which a later iteration enters after it ran" do
      entry = described_class.block_entry(narrowed, block("items.each { |i| r = $1; i =~ /(z)/ }"))

      expect(entry.global(:$1)).to be_nil
    end

    it "keeps them for a body that cannot match, since the block shares the frame" do
      expect(described_class.block_entry(narrowed, block("items.each { |i| $1 }"))).to equal(narrowed)
    end

    it "forgets them for any body in a frame that makes a closure that may match" do
      framed = narrowed.with_match_frame(root("f = proc { s =~ /(z)/ }"))

      expect(described_class.block_entry(framed, block("items.each { |i| $1 }")).global(:$1)).to be_nil
    end
  end
end
