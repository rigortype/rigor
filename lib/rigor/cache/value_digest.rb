# frozen_string_literal: true

require "digest"

module Rigor
  module Cache
    # Issue #1574 — a digest of a Ruby VALUE, not of its object graph. The same value digests to the same hex
    # string whether a producer computed it in this process or a cache entry served it from disk, whatever
    # Strings, Arrays or Hashes happen to share one object.
    #
    # `Marshal.dump` is not that function. It writes an object reached twice once and back-references it after,
    # and a Marshal round trip does not keep that sharing: `Marshal.load` rebuilds a String unfrozen, and
    # `Hash#[]=` then stores a frozen copy of it as the key rather than the String itself. A frozen String used
    # both as a row's field and as the key of an index Hash (rigor-sidekiq's `worker_index`, rigor-rails-i18n's
    # `locale_index`) therefore dumps to one set of bytes when computed and another when served, and a digest of
    # those bytes flipped the ADR-88 fact-surface fingerprint on every run that switched between the two.
    #
    # The encoding below walks the value as a tree. Each node is written as a type tag plus its content, and
    # sizes are length-prefixed, so the encoding is unambiguous and two values encode alike only when they are
    # alike. Nothing in it reads identity or frozenness. An object (a Data, a Struct, or any other non-core
    # object) is always written as its class name and the SHA-256 of its own encoding. That digest is taken once
    # per object and reused wherever the object is reached again, so a row shared between an index's list and
    # its by-name Hash is walked once, and the encoding is the same whether an object is shared or not.
    #
    # What it keeps, so a changed value still changes the digest:
    #
    # - every class distinction Marshal keeps: Integer vs Float, String vs Symbol, a subclass of String / Array /
    #   Hash / Set vs the base class, and the class name of every Data, Struct and plain object;
    # - Hash and Set iteration ORDER. Two Hashes equal under `==` but built in another order digest differently.
    #   A consumer may iterate a fact in order (the first matching row wins), and Marshal keeps the order, so the
    #   computed and served forms agree on it; digesting the order is the direction that can only over-invalidate;
    # - a Hash's `default` value, the `compare_by_identity` flag of a Hash or Set, a Range's `exclude_end?`, a
    #   Regexp's options, and a non-ASCII String's encoding. ASCII-only Strings digest alike in every encoding, as
    #   `==` has it.
    #
    # What it leaves out: instance variables set on a String, Array, Hash or Set, which `==` ignores too, and
    # modules or singleton methods an object was given.
    #
    # A plain object digests as its instance variables, sorted by name. An object that defines `marshal_dump` or
    # `_dump` digests as what that returns, which is what Marshal keeps of it.
    #
    # A value that cannot be digested this way raises {Uncanonicalisable}: an object whose state lives outside
    # its instance variables (a Proc, an IO, a Mutex: what `Marshal.dump` refuses), a Hash with a default proc, an
    # anonymous class, or a structure nested more than {MAX_DEPTH} deep, which is what a cycle becomes. A caller
    # must treat that as "unknown", never as "unchanged".
    module ValueDigest
      # The value has no canonical encoding. Fail closed: treat the value as moved.
      class Uncanonicalisable < StandardError; end

      # Containers nested deeper than this are refused. No fact is this deep; a cyclic structure is infinitely
      # deep, so this is also the cycle check, and it fires well before the Ruby stack would.
      MAX_DEPTH = 256

      module_function

      # The hex SHA-256 of `value`'s canonical encoding.
      def hexdigest(value)
        Encoder.new.hexdigest(value)
      rescue SystemStackError
        raise Uncanonicalisable, "#{value.class} is nested too deeply to digest"
      end

      # One walk of one value. The canonical bytes are fed to the SHA-256 in chunks, so a multi-megabyte fact
      # never has its whole encoding in memory at once.
      class Encoder
        FLUSH_AT = 64 * 1024
        private_constant :FLUSH_AT

        def initialize
          @sha = Digest::SHA256.new
          @out = String.new(capacity: FLUSH_AT * 2, encoding: Encoding::BINARY)
          @depth = 0
          @objects = {}.compare_by_identity # object => the SHA-256 of its encoding
          @symbols = {} # Symbol => its encoding
          @plain = {}.compare_by_identity # class => whether Marshal writes its instances as their ivars
        end

        def hexdigest(value)
          write(value)
          @sha.update(@out)
          @sha.hexdigest
        end

        private

        def write(value)
          case value
          when String then write_string(value)
          when Symbol then @out.append_as_bytes(@symbols[value] ||= encoded("y", value.name))
          when Hash then enter { write_hash(value) }
          when Array then enter { write_array(value) }
          when Set then enter { write_set(value) }
          when Integer then @out.append_as_bytes("i", value.to_s, ";")
          when nil then @out.append_as_bytes("n")
          when true then @out.append_as_bytes("t")
          when false then @out.append_as_bytes("f")
          else write_other(value)
          end
        end

        def write_other(value)
          case value
          when Float then @out.append_as_bytes("d", value.to_s, ";")
          when Range then enter { write_range(value) }
          when Regexp then write_regexp(value)
          when Rational then @out.append_as_bytes("q", value.numerator.to_s, "/", value.denominator.to_s, ";")
          when Complex then enter { write_pair("c", value.real, value.imaginary) }
          when Module then write_bytes(value.is_a?(Class) ? "k" : "m", class_name(value))
          else write_object(value)
          end
        end

        # The common case, an ASCII-only plain String, is written inline: it is most of the nodes of a large fact.
        def write_string(value)
          if value.ascii_only? && value.instance_of?(String)
            @out.append_as_bytes("s:", value.bytesize.to_s, ":", value)
          else
            write_subclass(value, String)
            write_bytes("s", value)
          end
          flush if @out.bytesize >= FLUSH_AT
        end

        # A tag and a String's bytes, length-prefixed. The encoding is written only for a String with non-ASCII
        # bytes: ASCII-only Strings compare equal whatever their encoding, and one built from a Symbol is
        # US-ASCII.
        def write_bytes(tag, string)
          @out.append_as_bytes(encoded(tag, string))
        end

        def encoded(tag, string)
          encoding = string.ascii_only? ? "" : string.encoding.name
          "#{tag}#{encoding}:#{string.bytesize}:".b.append_as_bytes(string)
        end

        def write_hash(value)
          raise Uncanonicalisable, "a Hash with a default proc" if value.default_proc

          write_subclass(value, Hash)
          default = value.default
          @out.append_as_bytes("h", value.compare_by_identity? ? "I" : "", default.nil? ? "" : "D",
                               value.size.to_s, ":")
          write(default) unless default.nil?
          value.each_pair do |key, entry|
            write(key)
            write(entry)
          end
        end

        def write_array(value)
          write_subclass(value, Array)
          @out.append_as_bytes("a", value.size.to_s, ":")
          value.each { |element| write(element) }
        end

        def write_set(value)
          write_subclass(value, Set)
          @out.append_as_bytes("e", value.compare_by_identity? ? "I" : "", value.size.to_s, ":")
          value.each { |element| write(element) }
        end

        def write_range(value)
          write_pair(value.exclude_end? ? "rx" : "ri", value.begin, value.end)
        end

        def write_pair(tag, first, second)
          @out.append_as_bytes(tag)
          write(first)
          write(second)
        end

        def write_regexp(value)
          @out.append_as_bytes("g", value.options.to_s, ";")
          write_bytes("s", value.source)
        end

        # Every object that is not a core value: its class name and the digest of its content, taken once per
        # object however often the value reaches it.
        def write_object(value)
          digest = @objects[value] ||= enter { object_digest(value) }
          write_bytes("o", class_name(value.class))
          @out.append_as_bytes(digest)
        end

        # The object's content, walked into a SHA-256 of its own. A `marshal_dump` / `_dump` hook decides what
        # Marshal keeps of an object, so it decides the digest too; otherwise a Data or Struct is its members and
        # anything else is its instance variables.
        def object_digest(value)
          outer_sha = @sha
          outer_out = @out
          @sha = Digest::SHA256.new
          @out = +"".b
          write_content(value)
          @sha.update(@out)
          @sha.digest
        ensure
          @sha = outer_sha
          @out = outer_out
        end

        def write_content(value)
          if value.respond_to?(:marshal_dump, true)
            @out.append_as_bytes("U")
            write(value.send(:marshal_dump))
          elsif value.is_a?(Time)
            # `Time#_dump` keeps the offset and zone as instance variables on the String it returns, which the
            # String encoding leaves out.
            @out.append_as_bytes("z")
            [value.to_r, value.utc_offset, value.zone].each { |part| write(part) }
          elsif value.respond_to?(:_dump, true)
            @out.append_as_bytes("u")
            write(value.send(:_dump, -1))
          else
            write_members(value)
          end
        end

        def write_members(value)
          case value
          when Data then write_fields("D", value.to_h)
          when Struct then write_fields("T", value.each_pair)
          else
            assert_plain(value)
            write_fields("V", value.instance_variables.sort.map { |name| [name, value.instance_variable_get(name)] })
          end
        end

        def write_fields(tag, pairs)
          fields = pairs.to_a
          @out.append_as_bytes(tag, fields.size.to_s, ":")
          fields.each do |name, field|
            write(name.to_sym)
            write(field)
          end
        end

        # An object's instance variables are all of its state only when Marshal writes it that way. `Marshal.dump`
        # refuses a Proc, an IO, a Mutex or a Thread (C-level state and no `_dump_data`), and so does this. The
        # depth limit of 1 makes the check cost one object: Marshal decides whether it can write the object
        # before it writes any instance variable, and raises `ArgumentError` on reaching the first one. It is
        # asked once per class, since whether a class keeps state outside Ruby does not vary by instance.
        def assert_plain(value)
          klass = value.class
          plain = @plain.fetch(klass) do
            @plain[klass] = begin
              Marshal.dump(value, 1)
              true
            rescue ArgumentError # "exceed depth limit": the object itself was written
              true
            rescue TypeError
              false
            end
          end
          raise Uncanonicalisable, "#{klass} keeps its state outside its instance variables" unless plain
        end

        # A subclass of a core value keeps its class through Marshal, so the class is part of the value.
        def write_subclass(value, base)
          klass = value.class
          write_bytes("C", class_name(klass)) unless klass.equal?(base)
        end

        def class_name(klass)
          klass.name || raise(Uncanonicalisable, "an anonymous #{klass.class.name.downcase} has no name to digest")
        end

        def enter
          raise Uncanonicalisable, "a value nested deeper than #{MAX_DEPTH} (a cycle?)" if @depth >= MAX_DEPTH

          @depth += 1
          begin
            result = yield
          ensure
            @depth -= 1
          end
          flush if @out.bytesize >= FLUSH_AT
          result
        end

        def flush
          @sha.update(@out)
          @out.clear
        end
      end
    end
  end
end
