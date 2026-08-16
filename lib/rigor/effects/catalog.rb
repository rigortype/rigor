# frozen_string_literal: true

require_relative "label_set"

module Rigor
  module Effects
    # The built-in effect catalogue — which core-library methods colour a summary, and with what
    # (ADR-103 WD3; the seed table is § 5.1 of `docs/design/20260816-effect-labels.md`).
    #
    # **This is a tracer-bullet catalogue, in Ruby, deliberately small.** The hand-audited artefact it
    # stands in for is `data/effects/core.yml`, which lands with #380 along with the per-class default
    # postures (value classes ∅, world-facing classes `io`) that make the exhaustiveness bit meaningful
    # over Ruby's whole core surface. Until then an uncatalogued call on a *known* receiver contributes
    # nothing and does not taint: a small proven lane is the honest state, and inventing `io` for every
    # unlisted `String` method would be worse than silence.
    #
    # What this catalogue is **not** is a re-reading of `data/builtins/ruby_core/*.yml`'s `purity:` facet.
    # That facet answers fold-safety in the C-dispatch sense — `Random#rand` is `leaf`, `Array#push` is
    # `leaf` — and reading it as effect freedom would be wrong in both directions (ADR-103 WD3).
    #
    # Keys are `Owner#method` for an instance-side row and `Owner.method` for a singleton-side one, which
    # is the spelling {FileCollection}'s method keys already use. `Kernel#…` rows match an implicit-self
    # call (and an explicit `self.` one); every other row matches its receiver by name.
    module Catalog
      # Constants that name an *object*, not a class, so their rows spell with `#` rather than `.`. `ENV`
      # is the one this slice catalogues; `ARGF` / `STDIN` / `STDOUT` / `STDERR` join it in #380.
      OBJECT_CONSTANTS = %w[ENV ARGF STDIN STDOUT STDERR].to_set.freeze

      # An explicit ∅ row. Distinct from "no row": a ∅ row says the catalogue *knows* this call and knows
      # it contributes nothing, which is what stops `Thread.new` from reading as an unresolved call while
      # its block joins the enclosing method by containment (WD4, WD14).
      NONE = LabelSet::EMPTY

      IO_STDOUT = LabelSet.new(["io.output.stdout"])
      private_constant :IO_STDOUT
      IO_STDERR = LabelSet.new(["io.output.stderr"])
      private_constant :IO_STDERR
      IO_INPUT = LabelSet.new(["io.input"])
      private_constant :IO_INPUT
      IO_PROCESS = LabelSet.new(["io.process"])
      private_constant :IO_PROCESS
      IO_ANY = LabelSet.new(["io"])
      private_constant :IO_ANY
      FS_READ = LabelSet.new(["io.fs.read"])
      private_constant :FS_READ
      FS_WRITE = LabelSet.new(["io.fs.write"])
      private_constant :FS_WRITE
      EXIT = LabelSet.new(["exit"])
      private_constant :EXIT
      RANDOM = LabelSet.new(["nondet.random"])
      private_constant :RANDOM
      TIME = LabelSet.new(["nondet.time"])
      private_constant :TIME
      GLOBAL_READ = LabelSet.new(["global.read"])
      private_constant :GLOBAL_READ
      GLOBAL_WRITE = LabelSet.new(["global.write"])
      private_constant :GLOBAL_WRITE
      # `require` and friends read the filesystem AND install constants and methods; WD14 fixes both.
      REQUIRE = LabelSet.new(["io.fs.read", "mutate.static"])
      private_constant :REQUIRE
      # `srand` re-seeds the process-wide generator as well as consuming entropy.
      SRAND = LabelSet.new(["global.write", "nondet.random"])
      private_constant :SRAND

      ROWS = {
        "Kernel#puts" => IO_STDOUT,
        "Kernel#print" => IO_STDOUT,
        "Kernel#p" => IO_STDOUT,
        "Kernel#pp" => IO_STDOUT,
        "Kernel#printf" => IO_STDOUT,
        "Kernel#putc" => IO_STDOUT,
        "Kernel#warn" => IO_STDERR,
        "Kernel#gets" => IO_INPUT,
        "Kernel#readline" => IO_INPUT,
        "Kernel#exit" => EXIT,
        "Kernel#exit!" => EXIT,
        "Kernel#abort" => EXIT,
        "Kernel#system" => IO_PROCESS,
        "Kernel#spawn" => IO_PROCESS,
        "Kernel#exec" => IO_PROCESS,
        "Kernel#fork" => IO_PROCESS,
        "Kernel#`" => IO_PROCESS,
        "Kernel#require" => REQUIRE,
        "Kernel#require_relative" => REQUIRE,
        "Kernel#load" => REQUIRE,
        # WD14 — `sleep` is `io`: it is a syscall whose duration the world decides, and no narrower label
        # in the shared vocabulary fits. `Queue#pop` / `ConditionVariable#wait` join it when they arrive.
        "Kernel#sleep" => IO_ANY,
        "Kernel#rand" => RANDOM,
        "Kernel#srand" => SRAND,
        "Random.rand" => RANDOM,
        "Random.new_seed" => RANDOM,
        "File.read" => FS_READ,
        "File.exist?" => FS_READ,
        "File.write" => FS_WRITE,
        "ENV#[]" => GLOBAL_READ,
        "ENV#fetch" => GLOBAL_READ,
        "ENV#[]=" => GLOBAL_WRITE,
        # WD14 — concurrency primitives carry no label; the block literal joins the enclosing method by
        # containment, which is where the work actually is.
        "Thread.new" => NONE,
        "Fiber.new" => NONE,
        "Ractor.new" => NONE,
        "Mutex#synchronize" => NONE
      }.freeze

      # Rows whose label depends on the call's arity rather than on its name alone. `Time.now` is always
      # `nondet.time`; `Time.new` is `nondet.time` only with no arguments, because `Time.new(2020, 1, 1)`
      # consults nothing (design note § 5.1).
      ZERO_ARITY_ROWS = {
        "Time.new" => TIME
      }.freeze

      ALWAYS_ROWS = {
        "Time.now" => TIME
      }.freeze

      module_function

      # The labels `key` contributes, or `nil` when the catalogue has no row for it. `argument_count` is
      # the call's positional arity, consulted only by the arity-dependent rows.
      #
      # A `nil` answer is not a taint: it means "no row", and the caller decides what an unrecognised call
      # on a known receiver means (today: nothing).
      def lookup(key, argument_count: 0)
        row = ROWS[key] || ALWAYS_ROWS[key]
        return row if row

        arity_row = ZERO_ARITY_ROWS[key]
        return arity_row if arity_row && argument_count.zero?

        nil
      end

      # Whether the catalogue would answer for `key` under any arity — the question "is this call known to
      # the catalogue at all", which is what keeps an arity-narrowed row (`Time.new(2020)`) from reading as
      # an unresolved call.
      def known?(key)
        ROWS.key?(key) || ALWAYS_ROWS.key?(key) || ZERO_ARITY_ROWS.key?(key)
      end
    end
  end
end
