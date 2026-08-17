# frozen_string_literal: true

require "prism"

require_relative "label_set"

module Rigor
  module Effects
    # Argument-dependent narrowing for catalogue rows (ADR-103 WD3; the row's `narrow:` names one of
    # these handlers, and `data/effects/core.yml` says why each row wants one).
    #
    # A handler reads **the call's own argument literals and nothing else**. There is no dataflow here
    # on purpose: the effect scan is observational (it never asks the typer for anything it did not
    # already decide), and a narrowing that depended on inference would make the catalogue's answer a
    # function of analysis quality rather than of the source in front of it.
    #
    # Every handler is total and answers an **upper bound**: when the literal does not settle the
    # question it returns the row's parent label, never a guess. `open(path)` with a computed argument
    # is `io` — file, pipe or URI — and that is the honest reading of the classic pipe-injection shape.
    #
    # Handlers are module functions dispatched by a `case`, deliberately not a Hash of lambdas: the
    # catalogue is loaded once per process and inherited across the fork pool, and a table of procs is
    # neither Marshal-clean nor shareable.
    module Narrowing
      IO_ANY = LabelSet.new(["io"]).freeze
      FS = LabelSet.new(["io.fs"]).freeze
      FS_READ = LabelSet.new(["io.fs.read"]).freeze
      FS_WRITE = LabelSet.new(["io.fs.write"]).freeze
      FS_READ_WRITE = LabelSet.new(["io.fs.read", "io.fs.write"]).freeze
      PROCESS = LabelSet.new(["io.process"]).freeze
      HTTP = LabelSet.new(["io.net.http"]).freeze
      TIME = LabelSet.new(["nondet.time"]).freeze
      DB = LabelSet.new(["io.db"]).freeze
      DB_READ = LabelSet.new(["io.db.read"]).freeze
      DB_WRITE = LabelSet.new(["io.db.write"]).freeze
      DB_TRANSACTION = LabelSet.new(["io.db.transaction"]).freeze
      RANDOM = LabelSet.new(["nondet.random"]).freeze
      NONE = LabelSet::EMPTY

      # Ruby's file modes, minus the encoding suffix (`"r:UTF-8"`) and the `b` / `t` flags. `"r"` is the
      # only pure read; every `+` form reads and writes.
      WRITE_MODES = %w[w a w+ a+ r+].freeze
      private_constant :WRITE_MODES

      # SQL verbs, by what they do to the database. `WITH` heads a CTE whose tail may be either, so it
      # deliberately does not narrow. Everything not listed answers `io.db`.
      SQL_READ_VERBS = %w[SELECT SHOW EXPLAIN DESCRIBE DESC PRAGMA].freeze
      SQL_WRITE_VERBS = %w[
        INSERT UPDATE DELETE REPLACE UPSERT MERGE TRUNCATE
        CREATE ALTER DROP RENAME COMMENT GRANT REVOKE REINDEX VACUUM ANALYZE COPY
      ].freeze
      SQL_TRANSACTION_VERBS = %w[BEGIN START COMMIT ROLLBACK SAVEPOINT RELEASE SET LOCK].freeze
      private_constant :SQL_READ_VERBS, :SQL_WRITE_VERBS, :SQL_TRANSACTION_VERBS

      HANDLERS = %w[kernel_open file_open pathname_open time_new random_new uri_open sql_verb].freeze

      module_function

      def known?(name)
        HANDLERS.include?(name)
      end

      # The labels `name`'s handler reads off `node`. An unknown handler name answers nil, which the
      # catalogue loader rejects at load time rather than at call time.
      def apply(name, node)
        case name
        when "kernel_open" then kernel_open(node)
        when "file_open" then file_open(node)
        when "pathname_open" then pathname_open(node)
        when "time_new" then time_new(node)
        when "random_new" then random_new(node)
        when "uri_open" then uri_open(node)
        when "sql_verb" then sql_verb(node)
        end
      end

      # `connection.execute(sql)` / `exec_query` / `select_all` — the SQL string's leading verb settles the
      # direction, which is the argument-dependent narrowing of the design note § 4 applied to SQL. It is
      # the one place a raw-SQL escape hatch can still be read precisely, and the shape that matters most —
      # `execute("UPDATE …")` inside a method whose envelope says `io.db.read` — is exactly the one a
      # literal answers.
      #
      # Interpolation is fine as long as the VERB is written out: `execute("SELECT * FROM #{table}")`
      # narrows, because {literal_prefix} keeps the leading literal run. A fully computed string does not,
      # and answers the parent `io.db`.
      def sql_verb(node)
        head = literal_prefix(argument(node, 0))
        return DB if head.nil?

        verb = head[/[A-Za-z]+/]&.upcase
        return DB if verb.nil?
        return DB_READ if SQL_READ_VERBS.include?(verb)
        return DB_WRITE if SQL_WRITE_VERBS.include?(verb)
        return DB_TRANSACTION if SQL_TRANSACTION_VERBS.include?(verb)

        DB
      end

      # `Kernel#open` — a path, a `|command` pipe, or (with open-uri loaded) a URI. A literal leading
      # `|` is the pipe form; anything else literal is a path, whose direction the mode literal decides.
      def kernel_open(node)
        target = literal_prefix(argument(node, 0))
        return IO_ANY if target.nil?
        return PROCESS if target.start_with?("|")

        mode_labels(node, 1)
      end

      # `File.open(path, mode)` — the mode literal decides the direction. An ABSENT mode is not an
      # unknown one: Ruby's default is `"r"`, so it reads. A mode the call computes — or an integer flag
      # such as `File::RDWR`, which the scan deliberately does not resolve — is genuinely unknown and
      # answers the subsystem parent.
      def file_open(node)
        mode_labels(node, 1)
      end

      # `Pathname#open(mode)` — the same reading one argument to the left, because the receiver is the
      # path.
      def pathname_open(node)
        mode_labels(node, 0)
      end

      # `Time.new` — with no positional arguments it is `Time.now`; with any it constructs from them and
      # consults no clock. Keyword arguments (`in:`) do not count: `Time.new(in: "+09:00")` is still now.
      def time_new(node)
        positional_count(node).zero? ? TIME : NONE
      end

      # `Random.new` — a seed argument makes the generator reproducible from the source; without one it
      # draws the seed from platform entropy.
      def random_new(node)
        positional_count(node).zero? ? RANDOM : NONE
      end

      # `URI.open` / `OpenURI.open_uri` — the scheme literal decides the subsystem. A bare path (no
      # `scheme://`) is open-uri's filesystem fallback; a scheme nobody rowed answers the parent.
      def uri_open(node)
        target = literal_prefix(argument(node, 0))
        return IO_ANY if target.nil?
        return HTTP if target.start_with?("http://", "https://")
        return FS_READ if target.start_with?("file://")
        return IO_ANY if target.include?("://")

        FS_READ
      end

      # The direction a mode argument proves. Three states, and the middle one is the reason this is not
      # a two-way test: **absent** is Ruby's `"r"` default, **present but unreadable** is genuinely
      # unknown and answers the subsystem parent, and **a literal** narrows.
      def mode_labels(node, index)
        mode = argument(node, index) || keyword_argument(node, "mode")
        return FS_READ if mode.nil?

        canonical = string_literal(mode)&.[](/\A[rwa]\+?/)
        return FS if canonical.nil?
        return FS_READ unless WRITE_MODES.include?(canonical)

        canonical.end_with?("+") ? FS_READ_WRITE : FS_WRITE
      end

      def argument(node, index)
        positional(node)[index]
      end

      def positional_count(node)
        positional(node).length
      end

      def positional(node)
        node.arguments&.arguments&.grep_v(Prism::KeywordHashNode) || []
      end

      def keyword_argument(node, name)
        hash = node.arguments&.arguments&.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
        pair = hash&.elements&.find do |element|
          element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) &&
            element.key.unescaped == name
        end
        pair&.value
      end

      def string_literal(node)
        node.unescaped if node.is_a?(Prism::StringNode)
      end

      # The literal head of a string argument: the whole thing for a plain literal, and the leading
      # literal run for an interpolated one. `open("|#{cmd}")` and `URI.open("https://#{host}/x")` are
      # the shapes that matter — the part that decides the subsystem is written out even when the rest
      # is computed.
      def literal_prefix(node)
        return node.unescaped if node.is_a?(Prism::StringNode)
        return nil unless node.is_a?(Prism::InterpolatedStringNode)

        head = node.parts.first
        head.is_a?(Prism::StringNode) ? head.unescaped : nil
      end

      private_class_method :sql_verb, :mode_labels, :argument, :positional_count, :positional,
                           :keyword_argument, :string_literal, :literal_prefix
    end
  end
end
