# frozen_string_literal: true

# Integration spec: runtime-value parity for the precision folds
# catalogued by the `rigor-type-coverage-uplift` skill.
#
# Every fold the skill adds (`ConstantFolding`, `ShapeDispatch`,
# the `*_folding` singleton modules) claims a *precise* result
# type for a statically-known call. This spec closes the loop:
# for each catalogued expression it
#
#   1. infers the type with the engine, and
#   2. evaluates the SAME source with MRI,
#
# then asserts the inferred type is consistent with the value the
# program actually produces. A fold that returns `Constant[4]`
# when Ruby yields `5`, or `Array[Elem]` when Ruby yields an
# `Enumerator`, fails here — the exact bug class that motivated
# the block-less-overload fix in `OverloadSelector`.
#
# Adding a new fold means adding one expression string to the
# `FOLD_PARITY_CASES` table; no other wiring is needed.

require "spec_helper"
require "tmpdir"
require "shellwords"
require "cgi"
require "uri"
require "date"

# One environment for the whole file. `for_project` loads
# `DEFAULT_LIBRARIES` (shellwords / cgi / uri / digest / ...),
# which the stdlib-module folds need; RBS itself loads lazily on
# the first inference query.
FOLD_PARITY_SCOPE = Rigor::Scope.empty(
  environment: Rigor::Environment.for_project(root: Dir.mktmpdir)
)

# method group => list of expression sources. Each source is
# parsed + typed by the engine AND `eval`-ed by MRI; the two
# results must agree.
FOLD_PARITY_CASES = {
  "String — ConstantFolding unary/binary" => [
    '"Hello".upcase', '"Hello".downcase', '"hello".capitalize', '"hello".swapcase',
    '"hi".reverse', '"hello".length', '"  hi  ".strip', '"hello".chop',
    "\"hello\\n\".chomp", '"hello".to_sym', '"42".to_i', '"3.14".to_f',
    '"a".ord', '"hello".succ', '"hello".empty?', '"".empty?',
    '"foo" + "bar"', '"ab" * 3', '"hello".start_with?("he")',
    '"hello".end_with?("lo")', '"hello".include?("ell")', '"hello" <=> "world"',
    '"hello".center(11)', '"hello".ljust(8, ".")', '"hello".rjust(8, ".")',
    '"hello".index("l")', '"hello".rindex("l")',
    '"hello".delete_prefix("he")', '"hello".delete_suffix("lo")',
    '"a".casecmp("A")', '"a".casecmp?("A")', '"abc".sum',
    '"a-b-c".partition("-")', '"a-b-c".rpartition("-")'
  ],
  "Integer — ConstantFolding unary/binary" => [
    "5.even?", "7.odd?", "0.zero?", "4.positive?", "(-2).negative?",
    "(-3).abs", "5.succ", "10.pred", "255.to_s(16)", "10.bit_length",
    "65.chr", "7 + 8", "20 - 5", "6 * 7", "2 ** 10", "17 % 5",
    "12.gcd(18)", "4.lcm(6)", "10.divmod(3)", "255 & 0x0F", "0x0F | 0xF0",
    "10 <=> 3", "5 == 5", "3.fdiv(2)",
    "5[0]", "5[1]", "7.ceildiv(2)", "5.to_r", "5.to_c",
    "255.digits(16)", "12.gcdlcm(8)"
  ],
  "Float — ConstantFolding" => [
    "3.14.floor", "3.14.ceil", "3.7.round", "2.5.to_i", "(-1.5).abs",
    "0.0.zero?", "1.0.nan?", "1.0.finite?", "(1.0 / 0.0).infinite?",
    "2.0 + 3.0", "10.0 / 4.0", "2.0 ** 3.0", "3.5.truncate",
    "3.0.quo(2)", "1.5.to_r", "1.5.rationalize"
  ],
  "Rational / Complex / Range — ConstantFolding" => [
    "Rational(1, 2) + Rational(1, 3)", "Rational(1, 2) ** 2",
    "Rational(1, 2).numerator", "Rational(3, 2).to_f", "Rational(6, 4).denominator",
    "Complex(1, 2) + Complex(3, 4)", "Complex(1, 2) * Complex(3, 4)",
    "Complex(3, 4).abs", "Complex(1, 2).conjugate", "Complex(1, 2).real",
    "(1..5).sum", "(1...5).sum"
  ],
  "Boolean — ConstantFolding" => [
    "true & false", "true | false", "true ^ true", "!false", "!!nil",
    "true.to_s", "false.to_s", "true == true", "false != true"
  ],
  "Array / Tuple — ShapeDispatch" => [
    "[3, 1, 2].sort", "[1, 2, 3].reverse", "[1, 2, 3].first", "[1, 2, 3].last",
    "[1, 2, 3].sum", "[1, 2, 3].min", "[1, 2, 3].max", "[1, 2, 3].size",
    "[1, 2, 3].length", "[1, 2, 3].count", "[1, 2, 2].include?(2)",
    "[1, 2, 3].empty?", "[].empty?", "[1, nil, 2].compact", "[1, 2, 3].take(2)",
    "[1, 2] + [3, 4]", "[10, 20, 30][1]",
    '[1, 2, 3].join("-")', "[1, 2, 3].join"
  ],
  "Hash — ShapeDispatch" => [
    "{ a: 1 }.merge(b: 2)", "{ a: 1, b: 2 }.keys", "{ a: 1, b: 2 }.values",
    "{ a: 1, b: 2 }.size", "{ a: 1, b: 2 }.to_a", "{ a: 1, b: 2 }.invert",
    "{ a: 1, b: 2 }.empty?", "{ a: 1, b: 2 }[:a]", "{ a: 1, b: 2 }.has_key?(:a)",
    "{ a: 1, b: 2 }.slice(:a)", "{ a: 1, b: 2 }.except(:a)"
  ],
  "Math — singleton folding" => [
    "Math.sqrt(16.0)", "Math.cbrt(27.0)", "Math.hypot(3.0, 4.0)",
    "Math.log2(8.0)", "Math.log10(1000.0)", "Math.exp(0.0)", "Math.atan2(0.0, 1.0)"
  ],
  "Shellwords — singleton folding" => [
    'Shellwords.escape("a b")', 'Shellwords.split("a b c")',
    'Shellwords.join(["a", "b", "c"])'
  ],
  "CGI / URI — singleton folding" => [
    'CGI.escape("a b")', 'CGI.unescape("a%20b")', 'CGI.escapeHTML("<x>")',
    'CGI.unescapeHTML("&lt;x&gt;")', 'URI.encode_www_form_component("a b")',
    'URI.decode_www_form_component("a+b")'
  ],
  "Regexp / File — singleton folding" => [
    'Regexp.escape("a.b")', 'File.basename("/x/y.rb")', 'File.extname("/x/y.rb")',
    'File.dirname("/x/y.rb")', 'File.join("a", "b")'
  ],
  "Array — per-element select/filter/reject fold" => [
    "[1, 2, 3, 4].select { |n| n.even? }", "[1, 2, 3, 4].filter { |n| n > 2 }",
    "[1, 2, nil].reject { |x| x.nil? }", "[1, 2, nil].reject(&:nil?)",
    "[1, 2, nil].select(&:nil?)", "[1, 2, 3, 4, 5].select(&:odd?)",
    "[1, 2, 3].reject { |n| n.positive? }", "[1, 2, 3].map(&:to_s)"
  ],
  "Enumerator — block-less iteration overload" => [
    "[1, 2, nil].filter", "[1, 2, 3].select", "[1, 2, 3].reject",
    "[1, 2, 3].map", "[1, 2, 3].collect", "[1, 2, 3].each",
    "[1, 2, 3].each_with_index", "(1..3).reverse_each", "[1, 2, 3].filter_map"
  ]
}.freeze

RSpec.describe "Fold runtime-value parity (integration)" do
  # Infers the type of a single Ruby expression by typing the
  # last statement of its parse tree under a pristine scope.
  def infer(source)
    node = Prism.parse(source).value.statements.body.last
    FOLD_PARITY_SCOPE.type_of(node)
  end

  # True when `value` (a real MRI runtime value) is a member of
  # the inferred `type`. Precise carriers are compared
  # structurally so a mismatch names the offending element; a
  # `Nominal` carrier (e.g. an `Enumerator` from a block-less
  # iteration call, or a still-imprecise `File.*` fold) is
  # checked by class membership; a refinement carrier
  # (`non-empty-string` and friends) is checked via `accepts`.
  def value_consistent_with_type?(type, value)
    case type
    when Rigor::Type::Constant  then constant_matches?(type, value)
    when Rigor::Type::Tuple     then tuple_matches?(type, value)
    when Rigor::Type::HashShape then hash_shape_matches?(type, value)
    when Rigor::Type::Union     then type.members.any? { |m| value_consistent_with_type?(m, value) }
    when Rigor::Type::Nominal   then nominal_matches?(type, value)
    else                             refinement_matches?(type, value)
    end
  end

  def constant_matches?(type, value)
    type.value == value && type.value.instance_of?(value.class)
  end

  def tuple_matches?(type, value)
    value.is_a?(Array) &&
      type.elements.size == value.size &&
      type.elements.zip(value).all? { |elem, v| value_consistent_with_type?(elem, v) }
  end

  def hash_shape_matches?(type, value)
    value.is_a?(Hash) &&
      type.pairs.size == value.size &&
      type.pairs.all? { |key, vt| value.key?(key) && value_consistent_with_type?(vt, value[key]) }
  end

  def nominal_matches?(type, value)
    klass = resolve_class(type.class_name)
    !klass.nil? && value.is_a?(klass)
  end

  # Refinement / range carriers (`Difference`, `IntegerRange`,
  # `Refined`): the scalar runtime value must be accepted.
  def refinement_matches?(type, value)
    literal = scalar_literal_for(value)
    !literal.nil? && type.accepts(literal, mode: :gradual).yes?
  end

  def resolve_class(name)
    Object.const_get(name)
  rescue NameError
    nil
  end

  def scalar_literal_for(value)
    Rigor::Type::Combinator.constant_of(value)
  rescue ArgumentError
    nil
  end

  FOLD_PARITY_CASES.each do |group, expressions|
    describe group do
      expressions.each do |expression|
        it "infers a type consistent with the runtime value of `#{expression}`" do
          inferred = infer(expression)
          runtime  = eval(expression) # rubocop:disable Security/Eval

          expect(value_consistent_with_type?(inferred, runtime)).to(
            be(true),
            "fold disagrees with MRI for `#{expression}`\n  " \
            "inferred type: #{inferred.describe(:short)} (#{inferred.class})\n  " \
            "runtime value: #{runtime.inspect} (#{runtime.class})"
          )
        end
      end
    end
  end
end
