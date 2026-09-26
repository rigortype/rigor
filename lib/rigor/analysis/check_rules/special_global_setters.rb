# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      # Issue #1367 (ADR-117 Decision point 1, WD2) — what the interpreter's setter for each special global accepts:
      # the envelope `global.write-type-mismatch` and `global.readonly-write` judge a write against.
      #
      # The setter is the authority, not the RBS declaration of the global. Where the two differ, the setter wins:
      # `$;` is declared `Regexp | String | nil`, but its setter also takes any object with `to_str`, and `$stdout` is
      # declared `IO`, but its setter takes anything that responds to `write`. Each entry names the CRuby function
      # that enforces it and was confirmed on Ruby 4.0.5, whose error the comment quotes.
      #
      # A special whose setter accepts every value is absent, so a write to it is never checked: `$stdin`
      # (ADR-117 WD2), `$_`, `$VERBOSE` / `$-v` / `$-w`, `$DEBUG` / `$-d` and `$=`. So is `$@`, whose setter raises
      # `ArgumentError` or `TypeError` depending on whether `$!` is set when it runs. `$&`, `` $` ``, `$'`, `$+`
      # and `$1`..`$9` cannot be assigned at all: that is a syntax error, not a write.
      module SpecialGlobalSetters
        # A setter that raises `TypeError` unless the value is an instance of one of `classes` (a subclass counts,
        # since the setter tests the object's built-in type) or, when `conversion` names a method, responds to it:
        # the implicit conversion the setter calls (`to_str`, `to_int`) or the method it asks `respond_to?` about
        # (`write`). `accepts` is the phrase the diagnostic quotes.
        Contract = Data.define(:classes, :conversion, :accepts) do
          # Whether an instance of the core class `class_name` is one the setter takes by type. Both sides are core
          # classes, whose hierarchy is Ruby's own, so the running interpreter answers it.
          def accepts_class?(class_name)
            klass = ::Object.const_get(class_name)
            classes.any? { |accepted| klass <= ::Object.const_get(accepted) }
          end
        end

        # `rb_str_setter` (string.c), reached through `rb_deprecated_str_setter` and io.c's `deprecated_rs_setter`,
        # tests `T_STRING` and calls no conversion: `$/ = 1` raises "value of $/ must be String", and so do a
        # `Regexp` and an object with `to_str`.
        STRING_OR_NIL = Contract.new(classes: %w[String NilClass].freeze, conversion: nil, accepts: "a String or nil")
        # `rb_fs_setter` (string.c): nil, a String, a Regexp, or an object with `to_str` (`rb_fs_check`).
        # `$; = 1` raises "value of $; must be String or Regexp".
        FIELD_SEPARATOR = Contract.new(
          classes: %w[String Regexp NilClass].freeze, conversion: :to_str,
          accepts: "a String, a Regexp, nil, or an object with `to_str'"
        )
        # `match_setter` (re.c): nil or a MatchData (`Check_Type(val, T_MATCH)`). `$~ = 1` raises
        # "wrong argument type Integer (expected MatchData)".
        MATCH_DATA = Contract.new(classes: %w[MatchData NilClass].freeze, conversion: nil,
                                  accepts: "a MatchData or nil")
        # `set_arg0` (ruby.c) calls `StringValueCStr`: a String or an object with `to_str`, and not nil. `$0 = 1`
        # raises "no implicit conversion of Integer into String".
        PROGRAM_NAME = Contract.new(
          classes: %w[String].freeze, conversion: :to_str, accepts: "a String or an object with `to_str'"
        )
        # `argf_lineno_setter` (io.c) calls `NUM2INT`: an Integer, a Float, or an object with `to_int`, and not nil.
        # `$. = "1"` raises "no implicit conversion of String into Integer".
        LINE_NUMBER = Contract.new(
          classes: %w[Integer
                      Float].freeze, conversion: :to_int, accepts: "an Integer, a Float, or an object with `to_int'"
        )
        # `opt_i_set` (io.c) through `argf_inplace_mode_set`: nil or false turns in-place mode off; anything else
        # goes through `StringValueCStr`. `$-i = 1` raises "no implicit conversion of Integer into String".
        INPLACE_MODE = Contract.new(
          classes: %w[String NilClass FalseClass].freeze, conversion: :to_str,
          accepts: "a String, nil, false, or an object with `to_str'"
        )
        # `stdout_setter` / `stderr_setter` (io.c) call `must_respond_to(id_write, …)`, which asks `respond_to?` and so
        # honours `respond_to_missing?`. `$stdout = 1` raises "$stdout must have write method, Integer given".
        # ADR-117 WD2: this `_Writer` requirement is the only contract a stream write is checked against.
        WRITER = Contract.new(classes: [].freeze, conversion: :write, accepts: "an object that responds to `write'")

        CONTRACTS = {
          "$/": STRING_OR_NIL,
          "$-0": STRING_OR_NIL,
          "$,": STRING_OR_NIL,
          "$\\": STRING_OR_NIL,
          "$;": FIELD_SEPARATOR,
          "$-F": FIELD_SEPARATOR,
          "$~": MATCH_DATA,
          "$0": PROGRAM_NAME,
          "$PROGRAM_NAME": PROGRAM_NAME,
          "$.": LINE_NUMBER,
          "$-i": INPLACE_MODE,
          "$stdout": WRITER,
          "$>": WRITER,
          "$stderr": WRITER
        }.freeze

        # The specials whose setter is `rb_gvar_readonly_setter` — declared with `rb_define_readonly_variable`, as a
        # virtual variable without a setter, or with that setter by name. Any write raises `NameError`
        # ("$! is a read-only variable"), whatever the value.
        #
        # - `$!` (eval.c); `$$` and `$?` (process.c).
        # - `$<`, `$FILENAME` and `$*` (io.c, ARGF).
        # - `$:` / `$LOAD_PATH` / `$-I`, `$"` / `$LOADED_FEATURES` (load.c).
        # - `$-W`, and the `-p` / `-l` / `-a` switches `$-p`, `$-l` and `$-a` (ruby.c).
        READ_ONLY = Set[
          :$!, :$$, :$?, :$<, :$FILENAME, :$*, :$:, :$LOAD_PATH, :$-I, :$", :$LOADED_FEATURES,
          :$-W, :$-p, :$-l, :$-a
        ].freeze

        module_function

        # The setter contract a write of `name` is checked against, or nil when its setter accepts every value or the
        # global is no special.
        # The literal nodes `global.write-type-mismatch` judges, by the core class of the object each evaluates to.
        # An interpolated String, Symbol or Regexp is still a new instance of that class.
        LITERAL_CLASSES = {
          Prism::IntegerNode => "Integer", Prism::FloatNode => "Float", Prism::RationalNode => "Rational",
          Prism::ImaginaryNode => "Complex", Prism::StringNode => "String", Prism::InterpolatedStringNode => "String",
          Prism::SymbolNode => "Symbol", Prism::InterpolatedSymbolNode => "Symbol", Prism::ArrayNode => "Array",
          Prism::HashNode => "Hash", Prism::RegularExpressionNode => "Regexp",
          Prism::InterpolatedRegularExpressionNode => "Regexp", Prism::NilNode => "NilClass",
          Prism::TrueNode => "TrueClass", Prism::FalseNode => "FalseClass"
        }.freeze

        # How the diagnostic names a literal of each class.
        LITERAL_DESCRIPTIONS = { "NilClass" => "nil", "TrueClass" => "true", "FalseClass" => "false" }.freeze

        def contract_for(name)
          CONTRACTS[name]
        end

        # The core class of the object `node` evaluates to when it is a literal ({LITERAL_CLASSES}), looking
        # through parentheses around a single expression, or nil for any other expression.
        def literal_class(node)
          while node.is_a?(Prism::ParenthesesNode)
            body = node.body
            return nil unless body.is_a?(Prism::StatementsNode) && body.body.size == 1

            node = body.body.first
          end
          LITERAL_CLASSES[node.class]
        end

        def literal_description(class_name)
          LITERAL_DESCRIPTIONS.fetch(class_name) do
            "#{class_name.start_with?('A', 'E', 'I', 'O', 'U') ? 'an' : 'a'} #{class_name} literal"
          end
        end

        def read_only?(name)
          READ_ONLY.include?(name)
        end
      end
    end
  end
end
