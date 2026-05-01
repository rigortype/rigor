#!/usr/bin/env ruby
# frozen_string_literal: true

# Extracts a PHPStan-functionMap-style catalog of Numeric/Integer/Float
# methods from the CRuby reference checkout at `references/ruby` and the
# RBS core signatures at `references/rbs/core`.
#
# This is a build-time tool, not part of the gem distribution. The
# generated YAML at `data/builtins/ruby_core/numeric.yml` is the output
# the inference engine will eventually consume; for now we just produce
# and commit the data so the shape is reviewable.
#
# Sources:
# - Init_Numeric() in references/ruby/numeric.c — flat C registration
#   block (rb_define_class / rb_define_method / rb_define_alias /
#   rb_define_const / rb_include_module). Parsed with regex over the
#   bracketed function body; this is robust because the block is a
#   straightforward sequence of single-statement macro calls.
# - references/ruby/numeric.rb — Ruby prelude. Parsed with Prism. We
#   record `Primitive.attr!` markers (notably `:leaf`) and the C
#   expression target of each `Primitive.cexpr!` body so the prelude
#   methods can be linked back to their underlying C function.
# - references/rbs/core/{numeric,integer,float}.rbs — RBS signatures
#   for the same classes. Parsed with the RBS gem and joined onto the
#   method records by (class, selector).
#
# Purity classification (initial pass; covers 1/3 of the eventual
# decision tree — C-body static analysis is the next slice):
#
# - `leaf`: prelude method carries `Primitive.attr! :leaf`. The CRuby
#   VM enforces that such iseqs do not call back into Ruby; treat as
#   safe to invoke during constant folding.
# - `trivial`: prelude method body is a single literal return (`self`,
#   `true`, `false`, `nil`, an Integer literal). Always safe.
# - `inline_block`: prelude method carries `Primitive.attr! :inline_block`
#   or `:use_block`. Block-dependent — fold only when the block is
#   itself proven pure.
# - `unknown`: everything else. Awaiting C-body analysis.

require "prism"
require "rbs"
require "yaml"

ROOT = File.expand_path("..", __dir__)

NUMERIC_C_PATH = File.join(ROOT, "references/ruby/numeric.c")
NUMERIC_RB_PATH = File.join(ROOT, "references/ruby/numeric.rb")
RBS_PATHS = {
  "Numeric" => File.join(ROOT, "references/rbs/core/numeric.rbs"),
  "Integer" => File.join(ROOT, "references/rbs/core/integer.rbs"),
  "Float" => File.join(ROOT, "references/rbs/core/float.rbs")
}.freeze

OUTPUT_PATH = File.join(ROOT, "data/builtins/ruby_core/numeric.yml")

# ---------------------------------------------------------------------
# C side: parse the Init_Numeric body.
# ---------------------------------------------------------------------

class CInitParser
  CLASS_DEFINE_RE = /^\s*(\w+)\s*=\s*rb_define_class\(\s*"([^"]+)"\s*,\s*(\w+)\s*\)\s*;/
  DEFINE_METHOD_RE = /^\s*rb_define_method\(\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*(\w+)\s*,\s*(-?\d+)\s*\)\s*;/
  DEFINE_SINGLETON_RE = /^\s*rb_define_singleton_method\(\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*(\w+)\s*,\s*(-?\d+)\s*\)\s*;/
  DEFINE_ALIAS_RE = /^\s*rb_define_alias\(\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)\s*;/
  DEFINE_CONST_RE = /^\s*rb_define_const\(\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*(.+?)\)\s*;/
  INCLUDE_MODULE_RE = /^\s*rb_include_module\(\s*(\w+)\s*,\s*(\w+)\s*\)\s*;/
  UNDEF_METHOD_RE = /^\s*rb_undef_method\(\s*(?:CLASS_OF\(\s*)?(\w+)\)?\s*,\s*"([^"]+)"\s*\)\s*;/

  # Hard-coded names used in numeric.c. Could be derived from the wider
  # codebase but pinning them here keeps this tool self-contained.
  CLASS_VAR_TO_NAME = {
    "rb_cObject" => "Object",
    "rb_cNumeric" => "Numeric",
    "rb_cInteger" => "Integer",
    "rb_cFloat" => "Float",
    "rb_eStandardError" => "StandardError",
    "rb_eRangeError" => "RangeError",
    "rb_mComparable" => "Comparable"
  }.freeze

  Result = Struct.new(:classes, :methods, :aliases, :constants, :includes, :undefs, keyword_init: true)

  def initialize(path)
    @path = path
    @lines = File.readlines(path)
  end

  def parse
    region = init_region
    var_to_class = CLASS_VAR_TO_NAME.dup

    classes = {}
    methods = []
    aliases = []
    constants = []
    includes = []
    undefs = []

    region.each do |lineno, line|
      next if class_definition(line, lineno, var_to_class, classes)
      next if method_definition(line, lineno, var_to_class, methods)
      next if singleton_definition(line, lineno, var_to_class, methods)
      next if alias_definition(line, lineno, var_to_class, aliases)
      next if const_definition(line, lineno, var_to_class, constants)
      next if include_definition(line, lineno, var_to_class, includes)
      next if undef_definition(line, lineno, var_to_class, undefs)
    end

    Result.new(
      classes: classes,
      methods: methods,
      aliases: aliases,
      constants: constants,
      includes: includes,
      undefs: undefs
    )
  end

  private

  def init_region
    start_idx = @lines.index { |l| l =~ /^Init_Numeric\(void\)/ }
    raise "Init_Numeric not found in #{@path}" unless start_idx

    open_idx = @lines[start_idx..].index { |l| l.start_with?("{") }
    raise "Init_Numeric body not found" unless open_idx

    body_start = start_idx + open_idx + 1
    depth = 1
    out = []
    (body_start...@lines.length).each do |i|
      line = @lines[i]
      depth += line.count("{")
      depth -= line.count("}")
      break if depth <= 0

      out << [i + 1, line]
    end
    out
  end

  def class_definition(line, lineno, var_to_class, classes)
    return false unless (m = line.match(CLASS_DEFINE_RE))

    var, name, parent_var = m.captures
    var_to_class[var] = name
    classes[name] = {
      "parent" => var_to_class.fetch(parent_var, parent_var),
      "defined_at" => "references/ruby/numeric.c:#{lineno}"
    }
    true
  end

  def method_definition(line, lineno, var_to_class, methods)
    return false unless (m = line.match(DEFINE_METHOD_RE))

    klass_var, selector, cfunc, arity = m.captures
    methods << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "selector" => selector,
      "kind" => "instance",
      "cfunc" => cfunc,
      "arity" => Integer(arity),
      "defined_at" => "references/ruby/numeric.c:#{lineno}"
    }
    true
  end

  def singleton_definition(line, lineno, var_to_class, methods)
    return false unless (m = line.match(DEFINE_SINGLETON_RE))

    klass_var, selector, cfunc, arity = m.captures
    methods << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "selector" => selector,
      "kind" => "singleton",
      "cfunc" => cfunc,
      "arity" => Integer(arity),
      "defined_at" => "references/ruby/numeric.c:#{lineno}"
    }
    true
  end

  def alias_definition(line, lineno, var_to_class, aliases)
    return false unless (m = line.match(DEFINE_ALIAS_RE))

    klass_var, new_name, old_name = m.captures
    aliases << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "new" => new_name,
      "old" => old_name,
      "defined_at" => "references/ruby/numeric.c:#{lineno}"
    }
    true
  end

  def const_definition(line, lineno, var_to_class, constants)
    return false unless (m = line.match(DEFINE_CONST_RE))

    klass_var, name, expr = m.captures
    constants << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "name" => name,
      "c_expression" => expr.strip,
      "defined_at" => "references/ruby/numeric.c:#{lineno}"
    }
    true
  end

  def include_definition(line, lineno, var_to_class, includes)
    return false unless (m = line.match(INCLUDE_MODULE_RE))

    klass_var, module_var = m.captures
    includes << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "module" => var_to_class.fetch(module_var, module_var),
      "defined_at" => "references/ruby/numeric.c:#{lineno}"
    }
    true
  end

  def undef_definition(line, lineno, var_to_class, undefs)
    return false unless (m = line.match(UNDEF_METHOD_RE))

    klass_var, selector = m.captures
    undefs << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "selector" => selector,
      "defined_at" => "references/ruby/numeric.c:#{lineno}"
    }
    true
  end
end

# ---------------------------------------------------------------------
# Prelude side: parse numeric.rb with Prism.
# ---------------------------------------------------------------------

class PreludeParser
  PreludeMethod = Struct.new(
    :class_name, :selector, :kind, :attrs, :arity,
    :body_kind, :cexpr_target, :cexpr_cfunc, :defined_at,
    keyword_init: true
  )

  CFUNC_RE = /\A([A-Za-z_]\w*)\s*\(/

  def initialize(path)
    @path = path
    @result = Prism.parse_file(path)
  end

  def parse
    methods = []
    aliases = []

    @result.value.statements.body.each do |klass_node|
      next unless klass_node.is_a?(Prism::ClassNode)

      class_name = klass_node.constant_path.slice
      collect_class_members(class_name, klass_node.body, methods, aliases)
    end

    [methods, aliases]
  end

  private

  def collect_class_members(class_name, body_node, methods, aliases)
    return unless body_node

    body_node.body.each do |node|
      case node
      when Prism::DefNode
        methods << build_method_record(class_name, node)
      when Prism::AliasMethodNode
        aliases << {
          "class" => class_name,
          "new" => node.new_name.unescaped,
          "old" => node.old_name.unescaped,
          "defined_at" => "references/ruby/numeric.rb:#{node.location.start_line}"
        }
      end
    end
  end

  def build_method_record(class_name, def_node)
    attrs, body_kind, cexpr_target = analyse_body(def_node.body)
    cexpr_cfunc = cexpr_target && CFUNC_RE.match(cexpr_target)&.[](1)

    PreludeMethod.new(
      class_name: class_name,
      selector: def_node.name.to_s,
      kind: def_node.receiver ? "singleton" : "instance",
      attrs: attrs,
      arity: parameter_arity(def_node.parameters),
      body_kind: body_kind,
      cexpr_target: cexpr_target,
      cexpr_cfunc: cexpr_cfunc,
      defined_at: "references/ruby/numeric.rb:#{def_node.location.start_line}"
    )
  end

  # Mimics CRuby's Method#arity for plain prelude defs.
  def parameter_arity(params)
    return 0 if params.nil?

    required = params.requireds.length
    optional = params.optionals.length
    rest = params.rest
    keywords = params.keywords.length + (params.keyword_rest ? 1 : 0)

    if optional.zero? && rest.nil? && keywords.zero?
      required
    else
      -(required + 1)
    end
  end

  def analyse_body(body)
    return [[], "empty", nil] unless body

    statements = body.body
    attrs = []
    cexpr_target = nil
    other_statements = []

    statements.each do |stmt|
      sym = primitive_attr_symbols(stmt)
      if sym
        attrs.concat(sym)
        next
      end
      target = primitive_cexpr_target(stmt)
      cexpr_target ||= target if target
      other_statements << stmt unless target
    end

    body_kind = classify_body(other_statements, cexpr_target)
    [attrs.uniq, body_kind, cexpr_target]
  end

  # Match `Primitive.attr! :leaf, :inline_block` and return the symbols.
  def primitive_attr_symbols(node)
    return nil unless node.is_a?(Prism::CallNode)
    return nil unless node.name == :attr!
    return nil unless node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Primitive

    (node.arguments&.arguments || []).filter_map do |arg|
      arg.is_a?(Prism::SymbolNode) ? arg.unescaped : nil
    end
  end

  # Match `Primitive.cexpr! 'rb_int_xxx(self)'` and return the C expression text.
  def primitive_cexpr_target(node)
    return nil unless node.is_a?(Prism::CallNode)
    return nil unless %i[cexpr! cstmt! cconst!].include?(node.name)
    return nil unless node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Primitive

    arg = node.arguments&.arguments&.first
    return nil unless arg.is_a?(Prism::StringNode)

    arg.unescaped.strip
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def classify_body(statements, cexpr_target)
    return "leaf_cexpr" if cexpr_target && statements.empty?
    return "leaf_cexpr_with_dispatch" if cexpr_target

    return "empty" if statements.empty?
    return "trivial_self" if statements.size == 1 && statements.first.is_a?(Prism::SelfNode)
    return "trivial_literal" if statements.size == 1 && literal?(statements.first)

    "composed"
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def literal?(node)
    case node
    when Prism::TrueNode, Prism::FalseNode, Prism::NilNode,
         Prism::IntegerNode, Prism::FloatNode, Prism::SymbolNode
      true
    else
      false
    end
  end
end

# ---------------------------------------------------------------------
# RBS side: signature lookups.
# ---------------------------------------------------------------------

class RbsCatalog
  Entry = Struct.new(:signatures, :line, keyword_init: true)

  def initialize(class_files)
    @methods = {}
    @aliases = {}

    class_files.each do |class_name, path|
      load_file(class_name, path)
    end
  end

  def method_signature(class_name, selector, kind)
    @methods[[class_name, kind, selector]]
  end

  def alias_for(class_name, new_name)
    @aliases[[class_name, new_name]]
  end

  private

  def load_file(class_name, path)
    content = File.read(path, encoding: "UTF-8")
    _buffer, _directives, decls = RBS::Parser.parse_signature(content)
    klass = decls.find do |d|
      d.is_a?(RBS::AST::Declarations::Class) && d.name.to_s.delete_prefix("::") == class_name
    end
    return unless klass

    klass.members.each do |member|
      case member
      when RBS::AST::Members::MethodDefinition
        record_method(class_name, path, member)
      when RBS::AST::Members::Alias
        record_alias(class_name, path, member)
      end
    end
  end

  def record_method(class_name, path, member)
    sigs = member.overloads.map { |o| o.method_type.to_s }
    line = member.location&.start_line
    rel = path.sub("#{ROOT}/", "")
    kind = member.kind == :singleton ? "singleton" : "instance"
    @methods[[class_name, kind, member.name.to_s]] = {
      "rbs" => sigs,
      "rbs_at" => line ? "#{rel}:#{line}" : rel
    }
  end

  def record_alias(class_name, path, member)
    line = member.location&.start_line
    rel = path.sub("#{ROOT}/", "")
    @aliases[[class_name, member.new_name.to_s]] = {
      "old" => member.old_name.to_s,
      "rbs_at" => line ? "#{rel}:#{line}" : rel
    }
  end
end

# ---------------------------------------------------------------------
# Merge + classify.
# ---------------------------------------------------------------------

class CatalogBuilder
  def initialize(c_result:, prelude_methods:, prelude_aliases:, rbs:)
    @c_result = c_result
    @prelude_methods = prelude_methods
    @prelude_aliases = prelude_aliases
    @rbs = rbs
  end

  def build
    classes = bootstrap_classes

    record_c_methods(classes)
    record_prelude_methods(classes)
    record_constants(classes)
    record_aliases(classes)
    record_includes(classes)

    {
      "schema_version" => 1,
      "generated_from" => generated_from,
      "purity_levels" => purity_levels,
      "classes" => classes
    }
  end

  private

  def generated_from
    {
      "ruby_init_c" => "references/ruby/numeric.c",
      "ruby_prelude" => "references/ruby/numeric.rb",
      "rbs" => RBS_PATHS.values.map { |p| p.sub("#{ROOT}/", "") }
    }
  end

  def purity_levels
    {
      "leaf" => "Prelude method carries Primitive.attr! :leaf — VM-enforced no-callout iseq.",
      "trivial" => "Prelude method body is a literal return (self/true/false/nil/Integer).",
      "inline_block" => "Prelude method carries :inline_block or :use_block; block-dependent.",
      "unknown" => "Awaiting C-body static classification."
    }
  end

  def bootstrap_classes
    classes = {}
    @c_result.classes.each do |name, info|
      classes[name] = {
        "parent" => info["parent"],
        "defined_at" => info["defined_at"],
        "includes" => [],
        "constants" => {},
        "aliases" => {},
        "instance_methods" => {},
        "singleton_methods" => {},
        "undefined" => []
      }
    end
    classes
  end

  def record_c_methods(classes)
    @c_result.methods.each do |entry|
      bucket = method_bucket(classes, entry["class"], entry["kind"])
      next unless bucket

      record = {
        "source" => "c",
        "cfunc" => entry["cfunc"],
        "arity" => entry["arity"],
        "defined_at" => entry["defined_at"],
        "purity" => "unknown"
      }
      apply_rbs(record, entry["class"], entry["selector"], entry["kind"])
      bucket[entry["selector"]] = record
    end

    @c_result.undefs.each do |entry|
      classes.dig(entry["class"], "undefined")&.push(entry["selector"])
    end
  end

  # rubocop:disable Metrics/AbcSize
  def record_prelude_methods(classes)
    @prelude_methods.each do |m|
      bucket = method_bucket(classes, m.class_name, m.kind)
      next unless bucket

      existing = bucket[m.selector]
      record = {
        "source" => existing ? "c+prelude" : "prelude",
        "prelude_attrs" => m.attrs,
        "body_kind" => m.body_kind,
        "cexpr_target" => m.cexpr_target,
        "prelude_at" => m.defined_at,
        "purity" => classify_purity(m)
      }
      record["arity"] = existing ? existing["arity"] : m.arity
      record["cfunc"] = existing ? existing["cfunc"] : m.cexpr_cfunc
      record["defined_at"] = (existing && existing["defined_at"]) || m.defined_at
      apply_rbs(record, m.class_name, m.selector, m.kind)
      bucket[m.selector] = record
    end
  end
  # rubocop:enable Metrics/AbcSize

  def record_constants(classes)
    @c_result.constants.each do |c|
      classes.dig(c["class"], "constants")&.[]=(c["name"], {
                                                  "c_expression" => c["c_expression"],
                                                  "defined_at" => c["defined_at"]
                                                })
    end
  end

  def record_aliases(classes)
    @c_result.aliases.each do |a|
      classes.dig(a["class"], "aliases")&.[]=(a["new"], {
                                                "old" => a["old"],
                                                "source" => "c",
                                                "defined_at" => a["defined_at"]
                                              })
    end
    @prelude_aliases.each do |a|
      classes.dig(a["class"], "aliases")&.[]=(a["new"], {
                                                "old" => a["old"],
                                                "source" => "prelude",
                                                "defined_at" => a["defined_at"]
                                              })
    end
  end

  def record_includes(classes)
    @c_result.includes.each do |inc|
      classes.dig(inc["class"], "includes")&.push({
                                                    "module" => inc["module"],
                                                    "defined_at" => inc["defined_at"]
                                                  })
    end
  end

  def classify_purity(prelude_method)
    return "leaf" if prelude_method.attrs.include?("leaf")
    return "inline_block" if prelude_method.attrs.intersect?(%w[inline_block use_block])
    return "trivial" if %w[trivial_self trivial_literal].include?(prelude_method.body_kind)

    "unknown"
  end

  def method_bucket(classes, class_name, kind)
    klass = classes[class_name]
    return nil unless klass

    kind == "singleton" ? klass["singleton_methods"] : klass["instance_methods"]
  end

  def apply_rbs(record, class_name, selector, kind)
    info = @rbs.method_signature(class_name, selector, kind)
    return unless info

    record["rbs"] = info["rbs"]
    record["rbs_at"] = info["rbs_at"]
  end
end

# ---------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------

c_result = CInitParser.new(NUMERIC_C_PATH).parse
prelude_methods, prelude_aliases = PreludeParser.new(NUMERIC_RB_PATH).parse
rbs = RbsCatalog.new(RBS_PATHS)

catalog = CatalogBuilder.new(
  c_result: c_result,
  prelude_methods: prelude_methods,
  prelude_aliases: prelude_aliases,
  rbs: rbs
).build

FileUtils.mkdir_p(File.dirname(OUTPUT_PATH)) if defined?(FileUtils)
require "fileutils"
FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))
File.write(OUTPUT_PATH, "# DO NOT EDIT — generated by tool/extract_numeric_catalog.rb\n#{catalog.to_yaml}")

stats = {
  classes: catalog["classes"].size,
  instance_methods: catalog["classes"].values.sum { |c| c["instance_methods"].size },
  singleton_methods: catalog["classes"].values.sum { |c| c["singleton_methods"].size },
  aliases: catalog["classes"].values.sum { |c| c["aliases"].size },
  constants: catalog["classes"].values.sum { |c| c["constants"].size },
  leaf: 0, trivial: 0, inline_block: 0, unknown: 0
}
catalog["classes"].each_value do |c|
  c["instance_methods"].each_value { |m| stats[m["purity"].to_sym] += 1 }
  c["singleton_methods"].each_value { |m| stats[m["purity"].to_sym] += 1 }
end
warn("Wrote #{OUTPUT_PATH}")
warn(stats.map { |k, v| "  #{k}: #{v}" }.join("\n"))
