# frozen_string_literal: true

module Tracer
  # The catalogue slice (#380): rows whose label the call's OWN argument literals decide, the object
  # constants, and the per-class default postures. Nothing here needs inference — every example is
  # settled by syntax the scan can read at the call site.
  class Narrowed
    # A literal leading `|` makes `Kernel#open` a subprocess rather than a file read. This is the
    # pipe-injection shape the design note calls out: the summary shows it.
    def pipe
      open("|ls")
    end

    # A literal path with no mode is Ruby's default `"r"`.
    def read_path
      open("/etc/hosts")
    end

    # The mode literal decides the direction; without it `File.open` would read.
    def write_file(path)
      File.open(path, "w")
    end

    # `ENV` names an object, not a class, so its rows spell `ENV#fetch` / `ENV#[]=` rather than `ENV.…`
    # — and the two directions carry different labels.
    def flag
      ENV.fetch("TRACER_FLAG", nil)
    end

    def set_flag
      ENV["TRACER_FLAG"] = "1"
    end

    # `Time.new` with arguments constructs from them and consults no clock, where `Time.now` reads one.
    def fixed_time
      Time.new(2020, 1, 1)
    end

    # A seeded generator is reproducible from the source.
    def seeded
      Random.new(42)
    end

    # A method of a world-facing class the catalogue does not row falls back to the class's posture —
    # here `STDOUT`'s, which is `io.output.stdout`.
    def drain
      STDOUT.flush
    end
  end
end
