#!/usr/bin/env ruby
# frozen_string_literal: true

# Extracts a PHPStan-functionMap-style catalog of CRuby built-in
# methods from the reference checkout at `references/ruby` and the
# RBS core signatures at `references/rbs`. Topics handled by this
# tool today: Numeric/Integer/Float, String/Symbol, and Array.
#
# Usage:
#   ruby tool/extract_builtin_catalog.rb              # all topics
#   ruby tool/extract_builtin_catalog.rb numeric      # one topic
#   ruby tool/extract_builtin_catalog.rb string array # several topics
#
# Each topic reads:
# - `Init_<Topic>()` in the matching `references/ruby/<topic>.c` —
#   flat C registration block (rb_define_class / _method / _alias /
#   _const / _include_module). Parsed with regex over the bracketed
#   function body; this is robust because the block is a
#   straightforward sequence of single-statement macro calls.
# - The matching `references/ruby/<topic>.rb` prelude (when one
#   exists). Parsed with Prism. Records `Primitive.attr!` markers
#   (notably `:leaf`) and the C target named inside
#   `Primitive.cexpr!` so each prelude method is linked back to its
#   underlying `rb_*` function.
# - The matching `references/rbs/core/<class>.rbs` files. Parsed
#   with the rbs gem and joined onto each (class, selector, kind)
#   record.
#
# Purity classification (per method):
#
# - `leaf` — prelude :leaf marker (VM-enforced), or C body uses no
#   dispatch / yield / mutation primitives.
# - `trivial` — prelude body is a single literal return (self /
#   true / false / nil / Integer literal).
# - `leaf_when_numeric` — C body falls through to
#   `rb_num_coerce_*` only when an operand is non-numeric; safe to
#   fold when every argument is itself a concrete numeric.
# - `inline_block` — prelude :inline_block / :use_block.
# - `block_dependent` — C body uses `rb_yield*` / `rb_block_given_p`.
# - `mutates_self` — C body calls `rb_check_frozen` (typical
#   prelude to mutation).
# - `dispatch` — C body calls user-redefinable methods (rb_funcall*,
#   rb_equal, rb_Float, num_funcall*, etc).
# - `unknown` — C body not located in indexed C files.

require "prism"
require "rbs"
require "yaml"
require "fileutils"
require "set"

ROOT = File.expand_path("..", __dir__)

# ---------------------------------------------------------------------
# Per-topic configuration table. Adding a new topic is purely a
# data change here — no class needs editing.
# ---------------------------------------------------------------------

# Class-variable globals that show up in any Init_* block. Each
# topic merges its own additions on top of this base.
BASE_CLASS_VARS = {
  "rb_cObject" => "Object",
  "rb_cBasicObject" => "BasicObject",
  "rb_eStandardError" => "StandardError",
  "rb_eRuntimeError" => "RuntimeError",
  "rb_eRangeError" => "RangeError",
  "rb_eTypeError" => "TypeError",
  "rb_eArgError" => "ArgumentError",
  "rb_eIndexError" => "IndexError",
  "rb_eKeyError" => "KeyError",
  "rb_eNotImpError" => "NotImplementedError",
  "rb_eNameError" => "NameError",
  "rb_eFrozenError" => "FrozenError",
  "rb_mComparable" => "Comparable",
  "rb_mEnumerable" => "Enumerable",
  "rb_mKernel" => "Kernel",
  "rb_cNumeric" => "Numeric",
  "rb_cInteger" => "Integer",
  "rb_cFloat" => "Float",
  "rb_cString" => "String",
  "rb_cSymbol" => "Symbol",
  "rb_cArray" => "Array",
  "rb_cHash" => "Hash",
  "rb_cRegexp" => "Regexp",
  "rb_cRange" => "Range",
  "rb_cEncoding" => "Encoding",
  "rb_cMatchData" => "MatchData",
  "rb_cSet" => "Set"
}.freeze

TOPICS = {
  "numeric" => {
    init_function: "Init_Numeric",
    ruby_c_path: "references/ruby/numeric.c",
    ruby_prelude_path: "references/ruby/numeric.rb",
    rbs_paths: {
      "Numeric" => "references/rbs/core/numeric.rbs",
      "Integer" => "references/rbs/core/integer.rbs",
      "Float" => "references/rbs/core/float.rbs"
    },
    c_index_paths: %w[references/ruby/numeric.c references/ruby/bignum.c],
    output_path: "data/builtins/ruby_core/numeric.yml"
  },
  "string" => {
    init_function: "Init_String",
    ruby_c_path: "references/ruby/string.c",
    ruby_prelude_path: nil,
    rbs_paths: {
      "String" => "references/rbs/core/string.rbs",
      "Symbol" => "references/rbs/core/symbol.rbs"
    },
    c_index_paths: %w[references/ruby/string.c],
    output_path: "data/builtins/ruby_core/string.yml"
  },
  "array" => {
    init_function: "Init_Array",
    ruby_c_path: "references/ruby/array.c",
    ruby_prelude_path: "references/ruby/array.rb",
    rbs_paths: {
      "Array" => "references/rbs/core/array.rbs"
    },
    c_index_paths: %w[references/ruby/array.c],
    output_path: "data/builtins/ruby_core/array.yml"
  },
  "io" => {
    init_function: "Init_IO",
    ruby_c_path: "references/ruby/io.c",
    ruby_prelude_path: "references/ruby/io.rb",
    rbs_paths: {
      "IO" => "references/rbs/core/io.rbs"
    },
    c_index_paths: %w[references/ruby/io.c],
    output_path: "data/builtins/ruby_core/io.yml"
  },
  "file" => {
    init_function: "Init_File",
    ruby_c_path: "references/ruby/file.c",
    ruby_prelude_path: nil,
    rbs_paths: {
      "File" => "references/rbs/core/file.rbs",
      "FileTest" => "references/rbs/core/file_test.rbs"
    },
    c_index_paths: %w[references/ruby/file.c],
    output_path: "data/builtins/ruby_core/file.yml"
  },
  "set" => {
    # Set was rewritten in C and folded into CRuby for Ruby 3.2+.
    # On the `ruby_4_0` reference branch the Init function lives
    # in `set.c`; there is no `set.rb` prelude (the C side calls
    # `rb_provide("set.rb")` at the end of Init_Set so a top-level
    # `require "set"` is a no-op against the built-in).
    init_function: "Init_Set",
    ruby_c_path: "references/ruby/set.c",
    ruby_prelude_path: nil,
    rbs_paths: {
      "Set" => "references/rbs/core/set.rbs"
    },
    c_index_paths: %w[references/ruby/set.c],
    output_path: "data/builtins/ruby_core/set.yml"
  }
}.freeze

# ---------------------------------------------------------------------
# C side: parse the Init_<Topic>() body.
# ---------------------------------------------------------------------

class CInitParser
  CLASS_DEFINE_RE = /^\s*(\w+)\s*=\s*rb_define_class\(\s*"([^"]+)"\s*,\s*(\w+)\s*\)\s*;/
  DEFINE_METHOD_RE = /^\s*rb_define_method\(\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*(\w+)\s*,\s*(-?\d+)\s*\)\s*;/
  DEFINE_SINGLETON_RE = /^\s*rb_define_singleton_method\(\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*(\w+)\s*,\s*(-?\d+)\s*\)\s*;/
  DEFINE_ALIAS_RE = /^\s*rb_define_alias\(\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)\s*;/
  DEFINE_CONST_RE = /^\s*rb_define_const\(\s*(\w+)\s*,\s*"([^"]+)"\s*,\s*(.+?)\)\s*;/
  INCLUDE_MODULE_RE = /^\s*rb_include_module\(\s*(\w+)\s*,\s*(\w+)\s*\)\s*;/
  UNDEF_METHOD_RE = /^\s*rb_undef_method\(\s*(?:CLASS_OF\(\s*)?(\w+)\)?\s*,\s*"([^"]+)"\s*\)\s*;/

  Result = Struct.new(:classes, :methods, :aliases, :constants, :includes, :undefs, keyword_init: true)

  def initialize(path:, init_function:, class_var_map:)
    @path = path
    @init_function = init_function
    @class_var_map = class_var_map
    @relative_path = path.sub("#{ROOT}/", "")
    @lines = File.readlines(path)
  end

  def parse
    region = init_region
    var_to_class = @class_var_map.dup

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
      classes: classes, methods: methods, aliases: aliases,
      constants: constants, includes: includes, undefs: undefs
    )
  end

  private

  def init_region
    re = /^#{Regexp.escape(@init_function)}\(void\)/
    start_idx = @lines.index { |l| l =~ re }
    raise "#{@init_function} not found in #{@path}" unless start_idx

    open_idx = @lines[start_idx..].index { |l| l.start_with?("{") }
    raise "#{@init_function} body not found" unless open_idx

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

  def loc(lineno)
    "#{@relative_path}:#{lineno}"
  end

  def class_definition(line, lineno, var_to_class, classes)
    return false unless (m = line.match(CLASS_DEFINE_RE))

    var, name, parent_var = m.captures
    var_to_class[var] = name
    classes[name] = { "parent" => var_to_class.fetch(parent_var, parent_var), "defined_at" => loc(lineno) }
    true
  end

  def method_definition(line, lineno, var_to_class, methods)
    return false unless (m = line.match(DEFINE_METHOD_RE))

    klass_var, selector, cfunc, arity = m.captures
    methods << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "selector" => selector, "kind" => "instance",
      "cfunc" => cfunc, "arity" => Integer(arity), "defined_at" => loc(lineno)
    }
    true
  end

  def singleton_definition(line, lineno, var_to_class, methods)
    return false unless (m = line.match(DEFINE_SINGLETON_RE))

    klass_var, selector, cfunc, arity = m.captures
    methods << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "selector" => selector, "kind" => "singleton",
      "cfunc" => cfunc, "arity" => Integer(arity), "defined_at" => loc(lineno)
    }
    true
  end

  def alias_definition(line, lineno, var_to_class, aliases)
    return false unless (m = line.match(DEFINE_ALIAS_RE))

    klass_var, new_name, old_name = m.captures
    aliases << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "new" => new_name, "old" => old_name, "defined_at" => loc(lineno)
    }
    true
  end

  def const_definition(line, lineno, var_to_class, constants)
    return false unless (m = line.match(DEFINE_CONST_RE))

    klass_var, name, expr = m.captures
    constants << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "name" => name, "c_expression" => expr.strip, "defined_at" => loc(lineno)
    }
    true
  end

  def include_definition(line, lineno, var_to_class, includes)
    return false unless (m = line.match(INCLUDE_MODULE_RE))

    klass_var, module_var = m.captures
    includes << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "module" => var_to_class.fetch(module_var, module_var), "defined_at" => loc(lineno)
    }
    true
  end

  def undef_definition(line, lineno, var_to_class, undefs)
    return false unless (m = line.match(UNDEF_METHOD_RE))

    klass_var, selector = m.captures
    undefs << {
      "class" => var_to_class.fetch(klass_var, klass_var),
      "selector" => selector, "defined_at" => loc(lineno)
    }
    true
  end
end

# ---------------------------------------------------------------------
# C body indexer + classifier.
# ---------------------------------------------------------------------

class CBodyIndex
  FUNC_HEADER_RE = /\A([A-Za-z_]\w*)\s*\(/
  TYPE_LINE_RE = /\b(?:VALUE|void|int|long|double|bool|char|short|unsigned|size_t|ID|rb_\w+_t)\b\s*\*?\s*\z/
  MACRO_ALIAS_RE = /\A\s*#\s*define\s+([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*$/

  Body = Struct.new(:cfunc, :path, :start_line, :text, keyword_init: true)

  def initialize(paths)
    @paths = paths
    @bodies = nil
    @aliases = {}
  end

  def lookup(cfunc)
    @bodies ||= build
    target = cfunc
    seen = Set.new
    while @aliases.key?(target) && !seen.include?(target)
      seen << target
      target = @aliases[target]
    end
    @bodies[target]
  end

  private

  def build
    bodies = {}
    @paths.each { |path| index_file(path, bodies) }
    bodies
  end

  def collect_macro_alias(line)
    return unless (m = line.match(MACRO_ALIAS_RE))

    @aliases[m[1]] = m[2]
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def index_file(path, bodies)
    lines = File.readlines(path)
    rel = path.sub("#{ROOT}/", "")

    i = 0
    while i < lines.length
      header = lines[i]
      collect_macro_alias(header)
      if (m = header.match(FUNC_HEADER_RE)) && i.positive?
        prev = lines[i - 1].rstrip
        if prev =~ TYPE_LINE_RE && !prev.end_with?(";") && !prev.lstrip.start_with?("#")
          name = m[1]
          j = i + 1
          j += 1 while j < lines.length && !lines[j].start_with?("{")
          if j < lines.length
            depth = 0
            k = j
            while k < lines.length
              depth += lines[k].count("{")
              depth -= lines[k].count("}")
              break if depth.zero?

              k += 1
            end
            if k < lines.length
              body_text = lines[j..k].join
              bodies[name] ||= Body.new(cfunc: name, path: rel, start_line: i + 1, text: body_text)
              i = k + 1
              next
            end
          end
        end
      end
      i += 1
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
end

module CBodyClassifier
  module_function

  DISPATCH_RE = /
    \b(?:
      rb_funcall\w* |
      rb_check_funcall\w* |
      num_funcall\d? |
      rb_exec_recursive\w* |
      do_coerce |
      rb_equal | rb_eql |
      rb_Float | rb_Integer | rb_String | rb_Array | rb_Hash |
      rb_to_int | rb_to_float | rb_to_str |
      rb_check_string_type |
      rb_convert_type\w* |
      rb_inspect |
      rb_method_basic_definition_p
    )\b
  /x
  COERCE_FALLBACK_RE = /\brb_num_coerce_(?:bin|cmp|relop)\b/
  BLOCK_RE = /\b(?:rb_yield\w*|rb_block_given_p|rb_iterator_p|rb_block_call\w*)\b/
  MUTATE_RE = /
    \b(?:
      rb_check_frozen\w* |
      rb_str_modify\w* |
      rb_str_resize |
      rb_str_set_len |
      rb_str_buf_cat\w* |
      rb_str_buf_append |
      rb_str_replace |
      rb_str_update |
      rb_ary_modify\w* |
      rb_ary_set_len |
      rb_ary_resize |
      rb_ary_replace |
      rb_ary_store |
      rb_ary_push\w* |
      rb_ary_pop |
      rb_ary_shift |
      rb_ary_unshift |
      rb_ary_concat\w* |
      rb_ary_splice |
      rb_ary_clear |
      rb_ary_delete\w* |
      rb_ary_insert |
      rb_ary_sort_bang |
      rb_hash_modify\w* |
      rb_hash_aset |
      rb_hash_delete\w* |
      rb_hash_clear |
      rb_obj_taint |
      rb_obj_freeze\w*
    )\b
  /x
  RAISE_RE = /\b(?:rb_raise\w*|rb_num_zerodiv|rb_cmperr\w*|rb_name_error\w*|rb_bug)\b/

  def classify(body_text)
    text = strip_comments(body_text)

    {
      block: text =~ BLOCK_RE ? true : false,
      mutate: text =~ MUTATE_RE ? true : false,
      coerce_fallback: text =~ COERCE_FALLBACK_RE ? true : false,
      dispatch: text =~ DISPATCH_RE ? true : false,
      raises: text =~ RAISE_RE ? true : false
    }
  end

  def strip_comments(text)
    text.gsub(%r{/\*.*?\*/}m, "").gsub(%r{//[^\n]*}, "")
  end
end

# ---------------------------------------------------------------------
# Prelude side: parse the *.rb prelude file (when present).
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
    @relative_path = path.sub("#{ROOT}/", "")
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
          "class" => class_name, "new" => node.new_name.unescaped, "old" => node.old_name.unescaped,
          "defined_at" => "#{@relative_path}:#{node.location.start_line}"
        }
      end
    end
  end

  def build_method_record(class_name, def_node)
    attrs, body_kind, cexpr_target = analyse_body(def_node.body)
    cexpr_cfunc = cexpr_target && CFUNC_RE.match(cexpr_target)&.[](1)

    PreludeMethod.new(
      class_name: class_name, selector: def_node.name.to_s,
      kind: def_node.receiver ? "singleton" : "instance",
      attrs: attrs, arity: parameter_arity(def_node.parameters),
      body_kind: body_kind, cexpr_target: cexpr_target, cexpr_cfunc: cexpr_cfunc,
      defined_at: "#{@relative_path}:#{def_node.location.start_line}"
    )
  end

  def parameter_arity(params)
    return 0 if params.nil?

    required = params.requireds.length
    optional = params.optionals.length
    rest = params.rest
    keywords = params.keywords.length + (params.keyword_rest ? 1 : 0)
    optional.zero? && rest.nil? && keywords.zero? ? required : -(required + 1)
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

    [attrs.uniq, classify_body(other_statements, cexpr_target), cexpr_target]
  end

  def primitive_attr_symbols(node)
    return nil unless node.is_a?(Prism::CallNode)
    return nil unless node.name == :attr!
    return nil unless node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Primitive

    (node.arguments&.arguments || []).filter_map do |arg|
      arg.is_a?(Prism::SymbolNode) ? arg.unescaped : nil
    end
  end

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
# RBS side.
# ---------------------------------------------------------------------

class RbsCatalog
  def initialize(class_files)
    @methods = {}
    @aliases = {}

    class_files.each { |class_name, path| load_file(class_name, path) }
  end

  def method_signature(class_name, selector, kind)
    @methods[[class_name, kind, selector]]
  end

  def alias_for(class_name, new_name)
    @aliases[[class_name, new_name]]
  end

  private

  def load_file(class_name, path)
    return unless File.exist?(path)

    content = File.read(path, encoding: "UTF-8")
    _buffer, _directives, decls = RBS::Parser.parse_signature(content)
    klass = decls.find do |d|
      d.is_a?(RBS::AST::Declarations::Class) && d.name.to_s.delete_prefix("::") == class_name
    end
    return unless klass

    klass.members.each do |member|
      case member
      when RBS::AST::Members::MethodDefinition then record_method(class_name, path, member)
      when RBS::AST::Members::Alias then record_alias(class_name, path, member)
      end
    end
  end

  def record_method(class_name, path, member)
    sigs = member.overloads.map { |o| o.method_type.to_s }
    line = member.location&.start_line
    rel = path.sub("#{ROOT}/", "")
    kind = member.kind == :singleton ? "singleton" : "instance"
    @methods[[class_name, kind, member.name.to_s]] = {
      "rbs" => sigs, "rbs_at" => line ? "#{rel}:#{line}" : rel
    }
  end

  def record_alias(class_name, path, member)
    line = member.location&.start_line
    rel = path.sub("#{ROOT}/", "")
    @aliases[[class_name, member.new_name.to_s]] = {
      "old" => member.old_name.to_s, "rbs_at" => line ? "#{rel}:#{line}" : rel
    }
  end
end

# ---------------------------------------------------------------------
# Merge + classify.
# ---------------------------------------------------------------------

class CatalogBuilder # rubocop:disable Metrics/ClassLength
  def initialize(c_result:, prelude_methods:, prelude_aliases:, rbs:, c_bodies:, topic_config:)
    @c_result = c_result
    @prelude_methods = prelude_methods
    @prelude_aliases = prelude_aliases
    @rbs = rbs
    @c_bodies = c_bodies
    @topic_config = topic_config
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
      "ruby_init_c" => @topic_config[:ruby_c_path],
      "ruby_prelude" => @topic_config[:ruby_prelude_path],
      "rbs" => @topic_config[:rbs_paths].values
    }
  end

  def purity_levels
    {
      "leaf" => "Prelude :leaf marker (VM-enforced) or C body uses no dispatch/yield/mutation.",
      "trivial" => "Prelude method body is a literal return (self/true/false/nil/Integer).",
      "leaf_when_numeric" => "C body falls through to rb_num_coerce_* only when an operand is non-numeric; safe to fold when every argument is a concrete numeric.",
      "inline_block" => "Prelude method carries :inline_block or :use_block; block-dependent.",
      "block_dependent" => "C body yields or checks rb_block_given_p.",
      "mutates_self" => "C body checks rb_check_frozen — typically a prelude to mutation.",
      "dispatch" => "C body calls user-redefinable methods (rb_funcall*, rb_equal, rb_Float, num_funcall*, etc).",
      "unknown" => "C body not located in indexed C files."
    }
  end

  def bootstrap_classes
    classes = {}
    @c_result.classes.each do |name, info|
      classes[name] = {
        "parent" => info["parent"], "defined_at" => info["defined_at"],
        "includes" => [], "constants" => {}, "aliases" => {},
        "instance_methods" => {}, "singleton_methods" => {}, "undefined" => []
      }
    end
    classes
  end

  def record_c_methods(classes)
    @c_result.methods.each do |entry|
      bucket = method_bucket(classes, entry["class"], entry["kind"])
      next unless bucket

      record = {
        "source" => "c", "cfunc" => entry["cfunc"],
        "arity" => entry["arity"], "defined_at" => entry["defined_at"]
      }
      apply_c_classification(record, entry["cfunc"])
      apply_rbs(record, entry["class"], entry["selector"], entry["kind"])
      bucket[entry["selector"]] = record
    end

    @c_result.undefs.each do |entry|
      classes.dig(entry["class"], "undefined")&.push(entry["selector"])
    end
  end

  def apply_c_classification(record, cfunc)
    body = @c_bodies.lookup(cfunc)
    unless body
      record["purity"] = "unknown"
      record["c_body_at"] = "not_found"
      return
    end

    record["c_body_at"] = "#{body.path}:#{body.start_line}"
    effects = CBodyClassifier.classify(body.text)
    record["c_effects"] = effects.select { |_, v| v }.keys.map(&:to_s)
    record["purity"] = c_purity_from_effects(effects)
  end

  def c_purity_from_effects(effects)
    return "block_dependent" if effects[:block]
    return "mutates_self" if effects[:mutate]
    return "dispatch" if effects[:dispatch]
    return "leaf_when_numeric" if effects[:coerce_fallback]

    "leaf"
  end

  # rubocop:disable Metrics/AbcSize
  def record_prelude_methods(classes)
    @prelude_methods.each do |m|
      bucket = method_bucket(classes, m.class_name, m.kind)
      next unless bucket

      existing = bucket[m.selector]
      record = {
        "source" => existing ? "c+prelude" : "prelude",
        "prelude_attrs" => m.attrs, "body_kind" => m.body_kind,
        "cexpr_target" => m.cexpr_target, "prelude_at" => m.defined_at,
        "purity" => classify_purity(m)
      }
      record["arity"] = existing ? existing["arity"] : m.arity
      record["cfunc"] = existing ? existing["cfunc"] : m.cexpr_cfunc
      record["defined_at"] = (existing && existing["defined_at"]) || m.defined_at
      record["c_body_at"] = existing["c_body_at"] if existing && existing["c_body_at"]
      record["c_effects"] = existing["c_effects"] if existing && existing["c_effects"]

      if !existing && m.cexpr_cfunc
        c_record = {}
        apply_c_classification(c_record, m.cexpr_cfunc)
        record["c_body_at"] = c_record["c_body_at"] if c_record["c_body_at"]
        record["c_effects"] = c_record["c_effects"] if c_record["c_effects"]
      end

      apply_rbs(record, m.class_name, m.selector, m.kind)
      bucket[m.selector] = record
    end
  end
  # rubocop:enable Metrics/AbcSize

  def record_constants(classes)
    @c_result.constants.each do |c|
      classes.dig(c["class"], "constants")&.[]=(c["name"], {
        "c_expression" => c["c_expression"], "defined_at" => c["defined_at"]
      })
    end
  end

  def record_aliases(classes)
    @c_result.aliases.each do |a|
      classes.dig(a["class"], "aliases")&.[]=(a["new"], {
        "old" => a["old"], "source" => "c", "defined_at" => a["defined_at"]
      })
    end
    @prelude_aliases.each do |a|
      classes.dig(a["class"], "aliases")&.[]=(a["new"], {
        "old" => a["old"], "source" => "prelude", "defined_at" => a["defined_at"]
      })
    end
  end

  def record_includes(classes)
    @c_result.includes.each do |inc|
      classes.dig(inc["class"], "includes")&.push({
        "module" => inc["module"], "defined_at" => inc["defined_at"]
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
# Per-topic driver.
# ---------------------------------------------------------------------

def run_topic(topic_name, config)
  c_path = File.join(ROOT, config[:ruby_c_path])
  c_result = CInitParser.new(
    path: c_path,
    init_function: config[:init_function],
    class_var_map: BASE_CLASS_VARS
  ).parse

  prelude_methods, prelude_aliases =
    if config[:ruby_prelude_path]
      PreludeParser.new(File.join(ROOT, config[:ruby_prelude_path])).parse
    else
      [[], []]
    end

  rbs_paths_abs = config[:rbs_paths].transform_values { |p| File.join(ROOT, p) }
  rbs = RbsCatalog.new(rbs_paths_abs)
  c_bodies = CBodyIndex.new(config[:c_index_paths].map { |p| File.join(ROOT, p) })

  catalog = CatalogBuilder.new(
    c_result: c_result, prelude_methods: prelude_methods,
    prelude_aliases: prelude_aliases, rbs: rbs, c_bodies: c_bodies,
    topic_config: config
  ).build

  output = File.join(ROOT, config[:output_path])
  FileUtils.mkdir_p(File.dirname(output))
  File.write(output, "# DO NOT EDIT — generated by tool/extract_builtin_catalog.rb\n#{catalog.to_yaml}")

  emit_stats(topic_name, output, catalog)
end

def emit_stats(topic_name, output, catalog)
  stats = Hash.new(0)
  stats[:classes] = catalog["classes"].size
  stats[:instance_methods] = catalog["classes"].values.sum { |c| c["instance_methods"].size }
  stats[:singleton_methods] = catalog["classes"].values.sum { |c| c["singleton_methods"].size }
  stats[:aliases] = catalog["classes"].values.sum { |c| c["aliases"].size }
  stats[:constants] = catalog["classes"].values.sum { |c| c["constants"].size }
  catalog["classes"].each_value do |c|
    c["instance_methods"].each_value { |m| stats[m["purity"].to_sym] += 1 }
    c["singleton_methods"].each_value { |m| stats[m["purity"].to_sym] += 1 }
  end
  warn("[#{topic_name}] wrote #{output}")
  warn(stats.map { |k, v| "  #{k}: #{v}" }.join("\n"))
end

selected = ARGV.empty? ? TOPICS.keys : ARGV.dup
unknown = selected - TOPICS.keys
abort("unknown topic(s): #{unknown.join(', ')}; available: #{TOPICS.keys.join(', ')}") unless unknown.empty?

selected.each do |topic_name|
  run_topic(topic_name, TOPICS.fetch(topic_name))
end
