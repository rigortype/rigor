# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"

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
  # run; since #1365 a call there forgets by itself too.
  describe ".operand_may_match?" do
    def operand_may_match?(source) = described_class.operand_may_match?(last_statement(source).arguments, scope)

    it "counts a call {Calls} counts on any receiver, a literal naming one, or a `yield`" do
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
      expect(operand_may_match?("log(row[:name], csv.split(','))")).to be(false)
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

    # Round-2 review of #1364: a Regexp constant from another file does not resolve (#1373), and a lambda, a `yield`
    # or a call on the method's own block in a block the frame hands out may rebind it as well.
    it "reads an unresolved constant as a possible Regexp, where the block scan reads it as a class" do
      source = "helper { |l| l.index(Pats::HEADER) }"

      expect(fallback?(source)).to be(true)
      expect(fallback?("helper { |l| case l when Pats::HEADER then l end }")).to be(true)
      expect(fallback?("helper { |l| case l when *Pats::ALL then l end }")).to be(true)
      expect(described_class.may_match?(last_statement(source).block.body, scope)).to be(false)
      expect(fallback?("helper { |l| case l when String then l end }")).to be(false)
    end

    it "reads a lambda literal broadly, and counts a `yield` or an own-block call in a block" do
      expect(fallback?("@b = ->(l, pattern) { l.index(pattern) }")).to be(true)
      expect(fallback?("helper { |a, b| yield a, b }")).to be(true)
      expect(forward?("def m(&blk) = helper { |a, b| blk.call(a, b) }", :blk)).to be(true)
      expect(forward?("def m(other, &blk) = helper { |a, b| other.call(a, b) }", :blk)).to be(false)
    end

    it "keeps its answer on the frame while the scope's local and instance-variable tables stay the same" do
      def_node = last_statement("def m(s) = log(s)")
      frame = Rigor::Inference::MatchRebinding::Frame.new(def_node.body, def_node.parameters)
      allow(described_class).to receive(:self_call_fallback?).and_call_original

      2.times { frame.self_call_fallback?(scope) }
      frame.self_call_fallback?(scope.with_local(:s, Rigor::Type::Combinator.nominal_of("String")))

      expect(described_class).to have_received(:self_call_fallback?).with(def_node.body, nil, anything).twice
    end

    it "answers for a method's parameter defaults on the frame" do
      def_node = last_statement("def m(s, f = on { |l| l =~ /(z)/ }) = log(s)")

      expect(Rigor::Inference::MatchRebinding::Frame.new(def_node.body, def_node.parameters).self_call_fallback?(scope))
        .to be(true)
      expect(Rigor::Inference::MatchRebinding::Frame.new(def_node.body).self_call_fallback?(scope)).to be(false)
    end
  end

  # Issue #1365 — Ruby runs a call's receiver chain and arguments in the caller's frame before the method.
  describe ".operands_may_rebind?" do
    def operands_may_rebind?(source, in_scope = scope)
      described_class.operands_may_rebind?(last_statement(source), in_scope)
    end

    it "counts a call there that rebinds `$~`, and a block there that may match" do
      expect(operands_may_rebind?("out.push(u.sub(/q/, ''))")).to be(true)
      expect(operands_may_rebind?("u.sub(/q/, '').size")).to be(true)
      expect(operands_may_rebind?("out.push([u.index(/(q)/)])")).to be(true)
      expect(operands_may_rebind?("items.select { |i| i =~ /(z)/ }.map(&:upcase)")).to be(true)
      expect(operands_may_rebind?("log(items.map { |i| i =~ /(z)/ })")).to be(true)
      expect(operands_may_rebind?("log(items.map(&handler))")).to be(true)
    end

    it "does not count the call's own method or block, a lambda, or a call that leaves `$~` alone" do
      expect(operands_may_rebind?("u.sub(/(z)/, '')")).to be(false)
      expect(operands_may_rebind?("items.each { |i| i =~ /(z)/ }")).to be(false)
      expect(operands_may_rebind?("register(-> { s =~ /(z)/ })")).to be(false)
      expect(operands_may_rebind?("items.select { |i| i.empty? }.map(&:upcase)")).to be(false)
      expect(operands_may_rebind?("out.push(row[:name], csv.split(','), \"\#{row[:name]}\")")).to be(false)
      expect(operands_may_rebind?("$stdout.puts(Integer(v = $2))")).to be(false)
    end

    it "keeps the answer on the frame, which every pass over the call asks" do
      node = last_statement("[u.index(/(q)/)].map { $1 }")
      framed = scope.with_match_frame(node)
      allow(described_class).to receive(:value_may_rebind?).and_call_original
      2.times { expect(described_class.operands_may_rebind?(node, framed)).to be(true) }
      expect(described_class).to have_received(:value_may_rebind?).with(node.receiver, framed).once
    end

    # The frame-wide fallback of an implicit-self call stays with statement-position calls, where it was before:
    # `value` and `emit(...)` in an operand are read by what they call.
    it "reads an implicit-self call there by what it calls, not by the frame's fallback" do
      body = Prism.parse("on { |l| l =~ /(z)/ }").value
      framed = scope.with_match_frame(body)
      expect(framed.match_frame.self_call_fallback?(framed)).to be(true)
      expect(operands_may_rebind?("value.upcase", framed)).to be(false)
      expect(operands_may_rebind?("$stdout.puts(emit('q'))", framed)).to be(false)
      expect(operands_may_rebind?(%q($stdout.puts(eval('"zz" =~ /(q)/'))), framed)).to be(true)
    end
  end

  describe ".value_may_rebind?" do
    def value_may_rebind?(source) = described_class.value_may_rebind?(last_statement(source), scope)

    it "counts a call in a literal's values, and a block literal there that may match" do
      expect(value_may_rebind?("[u.index(/(q)/)]")).to be(true)
      expect(value_may_rebind?("{ a: items.find { |i| i =~ /(z)/ } }")).to be(true)
      expect(value_may_rebind?("\"\#{items.map { |i| i =~ /(z)/ }}\"")).to be(true)
      expect(value_may_rebind?("u[/(q)/] rescue nil")).to be(true)
      expect(value_may_rebind?("u[/q(z)?/] ||= 'x'")).to be(true)
    end

    it "does not count a literal whose calls leave `$~` alone, or code that does not run here" do
      expect(value_may_rebind?("[row[:name], list.index(3)]")).to be(false)
      expect(value_may_rebind?("h[:k] ||= 1")).to be(false)
      expect(value_may_rebind?("[-> { s =~ /(z)/ }]")).to be(false)
      expect(value_may_rebind?("defined?(u.sub(/q/, ''))")).to be(false)
    end
  end

  # Issue #1365 — outside a block, a statement's calls are read on two terms, split by what the analyzer did before.
  describe Rigor::Inference::MatchRebinding::Calls do
    let(:combinator) { Rigor::Type::Combinator }
    let(:typed) do
      scope.with_local(:re, combinator.constant_of(/(q)/))
           .with_local(:str, combinator.nominal_of("String"))
           .with_local(:n, combinator.nominal_of("Integer"))
           .with_local(:maybe, combinator.union(combinator.nominal_of("Regexp"), combinator.constant_of(nil)))
           .with_local(:obj, combinator.nominal_of("Object"))
           .with_local(:key, combinator.untyped)
           .with_local(:dyn_re, combinator.dynamic(combinator.nominal_of("Regexp")))
           .with_local(:res, combinator.nominal_of("Array", type_args: [combinator.nominal_of("Regexp")]))
           .with_local(:strs, combinator.tuple_of(combinator.constant_of("a"), combinator.constant_of("b")))
    end

    # Each source declares the locals first, so they parse as reads of the bindings `typed` gives them.
    def call(source) = last_statement("re = str = n = maybe = obj = key = dyn_re = res = strs = nil; #{source}")
    def rebinds?(source, in_scope = typed) = described_class.rebinds?(call(source), in_scope)
    def forgets_by_name?(source) = described_class.forgets_by_name?(call(source), typed)

    describe ".forgets_by_name?" do
      it "keeps a lookup the table named only when every argument is a non-Regexp literal" do
        ["row[:name]", "csv.split(',')", "list.index(3)", "s.slice(0, 2)", "s[1..2]", "s.split", "h[nil]"]
          .each { |source| expect(forgets_by_name?(source)).to be(false), source }
        ["row[key]", "s.split(str)", "s.index(n)", "s.index(re)", "s.split(\"\#{sep}\")", "s.index(*strs)",
         "s.index(RebindRegexp.new('q'))", "row[[1]]"]
          .each { |source| expect(forgets_by_name?(source)).to be(true), source }
      end

      # `split` with no separator splits on `$;`, which a Regexp there makes a match.
      it "keeps a `split` on `$;` only while the file never writes `$;`" do
        expect(forgets_by_name?("s.split")).to be(false)
        expect(forgets_by_name?("s.split(nil, 2)")).to be(false)
        written = typed.with_discovery(typed.discovery.with(program_globals: { "$;": combinator.constant_of(",") }))
        ["s.split", "s.split(nil, 2)"].each do |source|
          expect(described_class.forgets_by_name?(call(source), written)).to be(true), source
        end
        expect(described_class.forgets_by_name?(call("s.split(',')"), written)).to be(false)
        dash_f = typed.with_discovery(typed.discovery.with(program_globals: { "$-F": combinator.constant_of(",") }))
        expect(described_class.forgets_by_name?(call("s.split"), dash_f)).to be(true)
      end

      # A flow type is not proof: `str` reads `String` here, but a stale type can say so of a Regexp (#1380).
      it "does not keep on a typed argument" do
        expect(forgets_by_name?("s.partition(str)")).to be(true)
        expect(forgets_by_name?("s.slice(n)")).to be(true)
      end

      it "keeps `match?`, `grep` without a block, and `===` on a literal or a class" do
        expect(forgets_by_name?("s.match?(re)")).to be(false)
        expect(forgets_by_name?("lines.grep(re)")).to be(false)
        expect(forgets_by_name?("String === s")).to be(false)
        expect(forgets_by_name?("'x' === s")).to be(false)
        expect(forgets_by_name?("lines.grep(re) { |l| l }")).to be(true)
        expect(forgets_by_name?("lines.grep('a') { |l| l }")).to be(false)
        expect(forgets_by_name?("re === s")).to be(true)
        expect(forgets_by_name?("KEYS === s")).to be(true)
        expect(forgets_by_name?("Some::Unknown === s")).to be(true)
        expect(forgets_by_name?("self === s")).to be(true)
      end

      it "keeps an implicit-self `start_with?` or `[]=` only on literals, and never an eval or a `send`" do
        expect(forgets_by_name?("start_with?('x')")).to be(false)
        expect(forgets_by_name?("start_with?(str)")).to be(true)
        expect(forgets_by_name?("self[:k] = value")).to be(false)
        expect(forgets_by_name?("self[key] = 1")).to be(true)
        expect(forgets_by_name?("eval('1')")).to be(true)
        expect(forgets_by_name?("send(:start_with?, 'x')")).to be(true)
        expect(forgets_by_name?("s =~ str")).to be(true)
      end
    end

    describe ".base_named?" do
      it "names the table's methods on any receiver, and {SelfCalls}' only where the call is implicit" do
        expect(described_class.base_named?(call("u.index(re)"), implicit: false)).to be(true)
        expect(described_class.base_named?(call("u.start_with?(re)"), implicit: false)).to be(false)
        expect(described_class.base_named?(call("start_with?(re)"), implicit: true)).to be(true)
        expect(described_class.base_named?(call("log(re)"), implicit: true)).to be(false)
      end
    end

    describe ".rebinds?" do
      it "counts `=~`, `!~`, `match`, `sub`, `gsub` and `scan` whatever their argument" do
        ["u =~ str", "u !~ /(z)/", "u.match('q')", "u.sub('q', '')", "u.gsub!(str, '')", "u.scan('q')"].each do |source|
          expect(rebinds?(source)).to be(true), source
        end
      end

      it "counts a lookup only with an argument known to be a Regexp" do
        ["u.split(/(,)/)", "u[re]", "u.index(maybe)", "u.byterindex(WORD_RE)", "u.index(dyn_re)",
         "u.index(Regexp.union('a', 'b'))", "u.index(*res)", "u.start_with?(/(z)/)", "items.any?(re)"]
          .each { |source| expect(rebinds?(source)).to be(true), source }
        ["u.split(',')", "row[:name]", "list.index(3)", "u.partition(str)", "u.slice(n, 2)", "u.start_with?(obj)",
         "row[key]", "u.index(Some::Unknown)", "items.any?(String)", "u.index(*strs)", "u.index(*)", "u[KEYS]"]
          .each { |source| expect(rebinds?(source)).to be(false), source }
      end

      # A class the environment places below `Regexp` is one; a project class it does not know is not.
      it "reads a Regexp subclass through the environment's class ordering" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "my_re.rbs"), "class MyRe < Regexp\nend\n")
          environment = Rigor::Environment.for_project(signature_paths: [dir])
          subclassed = Rigor::Scope.empty(environment: environment).with_local(:mine, combinator.nominal_of("MyRe"))
          unknown = Rigor::Scope.empty(environment: environment).with_local(:mine, combinator.nominal_of("Unrelated"))
          expect(described_class.rebinds?(last_statement("mine = nil; u.index(mine)"), subclassed)).to be(true)
          expect(described_class.rebinds?(last_statement("mine = nil; u.index(mine)"), unknown)).to be(false)
        end
      end

      it "reads a refinement, a difference and an intersection by their Regexp member" do
        regexp = combinator.nominal_of("Regexp")
        {
          Rigor::Type::Refined.new(regexp, :non_empty) => true,
          Rigor::Type::Difference.new(regexp, combinator.constant_of(nil)) => true,
          Rigor::Type::Intersection.new([regexp, combinator.nominal_of("Comparable")]) => true,
          Rigor::Type::Difference.new(combinator.nominal_of("String"), combinator.constant_of("")) => false
        }.each do |type, expected|
          bound = typed.with_local(:mine, type)
          expect(described_class.rebinds?(last_statement("mine = nil; u.index(mine)"), bound)).to be(expected)
        end
      end

      it "counts a `split` on `$;` only when the file writes a known Regexp there" do
        expect(rebinds?("u.split")).to be(false)
        regexp = typed.with_discovery(typed.discovery.with(program_globals: { "$;": combinator.constant_of(/(,)/) }))
        comma = typed.with_discovery(typed.discovery.with(program_globals: { "$;": combinator.constant_of(",") }))
        expect(described_class.rebinds?(call("u.split"), regexp)).to be(true)
        expect(described_class.rebinds?(call("u.split(nil, 2)"), regexp)).to be(true)
        expect(described_class.rebinds?(call("u.split(',')"), regexp)).to be(false)
        expect(described_class.rebinds?(call("u.split"), comma)).to be(false)
      end

      it "never counts `match?`, and counts `grep` / `grep_v` only in their block form" do
        expect(rebinds?("u.match?(/(z)/)")).to be(false)
        expect(rebinds?("lines.grep(/(z)/)")).to be(false)
        expect(rebinds?("lines.grep(/(z)/) { |l| l }")).to be(true)
        expect(rebinds?("lines.grep_v(re, &handler)")).to be(true)
        expect(rebinds?("lines.grep(String) { |l| l }")).to be(false)
      end

      it "reads `===` and unary `~` by whether their receiver is known to be a Regexp" do
        expect(rebinds?("/(q)/ === u")).to be(true)
        expect(rebinds?("re === u")).to be(true)
        expect(rebinds?("Some::Unknown === u")).to be(false)
        expect(rebinds?("String === u")).to be(false)
        expect(rebinds?("~/(z)/")).to be(true)
        expect(rebinds?("~n")).to be(false)
      end

      it "reads `[]=` and an index compound write by the index, not the value stored" do
        expect(rebinds?("u[/(q)/] = 'x'")).to be(true)
        expect(rebinds?("h[:k] = /(q)/")).to be(false)
        expect(rebinds?("h[key] = 1")).to be(false)
        expect(rebinds?("u[/(q)/] ||= 'x'")).to be(true)
        expect(rebinds?("u[re] += 'x'")).to be(true)
        expect(rebinds?("h[key] += 1")).to be(false)
      end

      it "counts an eval of a String whose code may match, and not one it cannot read" do
        expect(rebinds?(%q|Kernel.eval('"zz" =~ /(q)/')|)).to be(true)
        expect(rebinds?(%q|binding.eval('x.sub("a", "")')|)).to be(true)
        expect(rebinds?(%q|obj.instance_eval("x = #{n}; 'zz' =~ /(q)/")|)).to be(true)
        expect(rebinds?('klass.class_eval("def foo; end")')).to be(false)
        expect(rebinds?("klass.class_eval(\"def \#{name}; @\#{name} =~ /(q)/; end\")")).to be(false)
        # An interpolated String that does not parse with its interpolations standing for a name counts when its
        # literal text names a match.
        expect(rebinds?("klass.class_eval(\"\#{name} =~ /(q)/ if\")")).to be(true)
        expect(rebinds?("klass.class_eval(\"\#{name}( 1\")")).to be(false)
        expect(rebinds?("Kernel.eval('x =~ ')")).to be(false)
        expect(rebinds?("klass.class_eval { attr_reader :x }")).to be(false)
        expect(rebinds?("node.eval")).to be(false)
      end

      # `binding.eval` and `Kernel.eval` exist to run code in this frame; `class_eval` and its kin of a variable are
      # the method-defining idiom.
      it "counts `binding.eval` and `Kernel.eval` of code it cannot read, and no other eval of such code" do
        ["binding.eval(src)", "proc {}.binding.eval(src)", "Kernel.eval(src)", "::Kernel.eval(src, b)",
         "binding.send(:eval, src)"].each { |source| expect(rebinds?(source)).to be(true), source }
        ["klass.class_eval(src)", "obj.instance_eval(src)", "mod.module_eval(src)", "Kernel.instance_eval(src)",
         "calc.eval(src)", "Foo::Kernel.eval(src)"].each { |source| expect(rebinds?(source)).to be(false), source }
      end

      # A deeply nested literal would overflow the scan's recursion, so it is read by its tokens.
      it "reads code nested too deeply, or too long, by its tokens without raising" do
        deep = "#{"[" * 3000}1#{"]" * 3000}"
        matching = "#{"[" * 3000}\"zz\" =~ /(q)/#{"]" * 3000}"
        expect(rebinds?("Kernel.eval('#{deep}')")).to be(false)
        expect(rebinds?("Kernel.eval('#{matching}')")).to be(true)
        expect(rebinds?("klass.class_eval('#{"x = 1\n" * 20_000}')")).to be(false)
        expect(rebinds?("klass.class_eval('#{"x = 1\n" * 20_000}s =~ /q/')")).to be(true)
      end

      it "does not parse code past the bounds" do
        node = call("Kernel.eval('#{"[" * 3000}1#{"]" * 3000}')")
        allow(Prism).to receive(:parse).and_call_original
        described_class.rebinds?(node, typed)
        expect(Prism).not_to have_received(:parse)
      end

      # Each pass over the call asks again; the frame keeps the parsed answer.
      it "keeps the answer for an eval's code on the frame" do
        node = call(%q|Kernel.eval('"zz" =~ /(q)/')|)
        framed = typed.with_match_frame(node)
        allow(Prism).to receive(:parse).and_call_original
        2.times { expect(described_class.rebinds?(node, framed)).to be(true) }
        expect(Prism).to have_received(:parse).once
      end

      it "survives a scan that overflows the stack, reading the code by its tokens" do
        allow(Rigor::Inference::MatchRebinding).to receive(:program_may_match?).and_raise(SystemStackError)
        expect(rebinds?(%q|Kernel.eval('"zz" =~ /(q)/')|)).to be(true)
        expect(rebinds?("klass.class_eval('def foo; end')")).to be(false)
      end

      it "reads a `send` by the method it names, or by the arguments a computed name is sent" do
        expect(rebinds?("u.send(:=~, re)")).to be(true)
        expect(rebinds?("u.public_send(name, re)")).to be(true)
        expect(rebinds?("u.__send__('[]', /(q)/)")).to be(true)
        expect(rebinds?("u.public_send(name)")).to be(false)
        expect(rebinds?("sock.send(packet, 0)")).to be(false)
        expect(rebinds?("record.public_send(\"\#{attr}=\", re)")).to be(false)
        expect(rebinds?("record.public_send(:\"\#{attr}=\", re)")).to be(false)
        expect(rebinds?("u.public_send(\"\#{op}==\", re)")).to be(true)
        expect(rebinds?("u.__send__(:[], :k)")).to be(false)
        expect(rebinds?("u.send(:match?, /x/)")).to be(false)
        expect(rebinds?("u.send(:upcase)")).to be(false)
        expect(rebinds?('u.send("\xff", 1)')).to be(false)
      end

      it "counts a forwarded `...` in neither reading as a known Regexp, and in the name reading as a non-literal" do
        forwarding = Prism.parse("def m(u, ...) = u.index(...)").value.statements.body.first.body.body.first
        expect(described_class.rebinds?(forwarding, typed)).to be(false)
        expect(described_class.forgets_by_name?(forwarding, typed)).to be(true)
      end
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

    # The name cannot show a `tap` / `then` / `yield_self` block runs once (#1375), so its entry reads the body as
    # every block's was read before #1364, without `!~` and the Regexp-valued `start_with?` family.
    it "reads a `tap` / `then` / `yield_self` body without the names #1364 added" do
      call = last_statement("line.then { |l| r = $1; l !~ /x/ }")
      matching = last_statement("line.then { |l| r = $1; l =~ /x/ }")

      expect(described_class.block_entry(narrowed, call.block, call)).to equal(narrowed)
      expect(described_class.block_entry(narrowed, call.block).global(:$1)).to be_nil
      expect(described_class.block_entry(narrowed, matching.block, matching).global(:$1)).to be_nil
    end

    it "forgets them for any body in a frame that makes a closure that may match" do
      framed = narrowed.with_match_frame(root("f = proc { s =~ /(z)/ }"))

      expect(described_class.block_entry(framed, block("items.each { |i| $1 }")).global(:$1)).to be_nil
    end

    # Issue #1365 — the call's receiver chain and arguments run before it yields.
    it "forgets them, given the owning call, when its receiver chain or arguments are known to match" do
      rebound = last_statement("[u.index(/(q)/)].map { $1 }")
      plain = last_statement("[row[:k]].map { $1 }")

      expect(described_class.block_entry(narrowed, rebound.block, rebound).global(:$1)).to be_nil
      expect(described_class.block_entry(narrowed, rebound.block)).to equal(narrowed)
      expect(described_class.block_entry(narrowed, plain.block, plain)).to equal(narrowed)
    end
  end
end
