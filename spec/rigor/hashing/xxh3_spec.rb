# frozen_string_literal: true

require "spec_helper"
require "rigor/hashing/xxh3"

RSpec.describe Rigor::Hashing::XXH3 do
  describe ".digest64" do
    # The upstream xxHash sanity-check input: `xsum_sanity_check.c`'s `XSUM_fillTestBuffer`, which
    # every XXH3 test vector hashes a prefix of. Its generator constants are PRIME32 = 2654435761
    # and a PRIME64 of 11400714785074694797 — note that generator's PRIME64 ends `...CA8D`, one hex
    # digit off `XXH_PRIME64_1` (`...CA87`); they are different constants.
    def sanity_buffer
      gen = 2_654_435_761
      String.new(encoding: Encoding::BINARY, capacity: 2367).tap do |buf|
        2367.times do
          buf << ((gen >> 56) & 0xFF)
          gen = (gen * 11_400_714_785_074_694_797) & 0xFFFF_FFFF_FFFF_FFFF
        end
      end
    end

    # `XSUM_XXH3_testdata` (xxHash `tests/sanity_test_vectors.h`), seed-0 entries only — {length =>
    # expected XXH3_64bits(sanity_buffer[0, length])}. The set spans every length regime of the
    # algorithm, including the regime boundaries and the striped long path (241+, and >1024 where
    # the scramble step repeats).
    upstream_vectors = {
      # len 0 and 1-3
      0 => "2d06800538d394c2", 1 => "c44bdff4074eecdb", 2 => "7a9978044cb8a8bb", 3 => "54247382a8d6b94d",
      # len 4-8
      4 => "e5dc74bc51848a51", 5 => "e4243f00720306bb", 6 => "27b56a84cd2d7325", 7 => "9941e0007f555e50",
      8 => "24ccc9acaa9f65e4",
      # len 9-16
      9 => "14d5001c15dd3f2b", 10 => "1c117f233fbc3c14", 11 => "889839b4c796ddd6", 12 => "a713daf0dfbb77e7",
      13 => "2eb03c6e66ba6524", 14 => "1ac0bbda2b9fcf03", 15 => "45556d4d6e1798bc", 16 => "981b17d36c7498c9",
      # len 17-128
      17 => "796f5acd3a60f862", 31 => "5d516692ca764c50", 32 => "9feaddbdbf57eed3", 33 => "abfb2d081b400a10",
      63 => "83d74a75f2c2577a", 64 => "9cb48487720ec49d", 65 => "fd81aac4bebc3883", 95 => "c0dd460b48116cda",
      96 => "935a769a7f94776f", 97 => "ca4ca268fd3c3a6c", 100 => "93cd95432b7d483f", 127 => "2408ed71323d6096",
      128 => "fcff24126754d861",
      # len 129-240
      129 => "98f1b0a679a2ca29", 159 => "7cb32a6ecdebaf1c", 160 => "9d03a319ed4cbd2b", 191 => "759ffc8ff8fb94bd",
      192 => "af9f58e78b8d3587", 200 => "bddca58935d7c038", 223 => "6e495316b983036e", 224 => "3f3250c7e92c871a",
      225 => "1e93dc9165079888", 239 => "16ce2b9d3b28805d", 240 => "81c3c2b67f568ccf",
      # len 241+ — the striped long path: accumulate_512 + scramble per 1024-byte block
      241 => "c5a639ecd2030e5e", 242 => "967344e78cb4b723", 255 => "e98f979f4ed8a197", 256 => "55de574ad89d0ac5",
      500 => "ef35aceb3b341a05", 511 => "8089715b163e7fc0", 512 => "617e49599013cb6b", 513 => "f7037d3b6722aeec",
      1000 => "aca2dde0f1951b9a", 1023 => "87a8f7b2f2e22496", 1024 => "dd85c9b5c1109c5c", 1025 => "d870c0fa13211c6a",
      2048 => "dd59e2c3a5f038e0", 2367 => "cb37aeb9e5d361ed"
    }

    upstream_vectors.each do |len, expected|
      it "hashes a #{len}-byte input to 0x#{expected}" do
        expect(described_class.digest64(sanity_buffer.byteslice(0, len))).to eq(expected.to_i(16))
      end
    end
  end

  # lisplens cross-check fixture (ADR-113 WD6): the same byte strings hashed by lisplens's
  # `xxhash-rust` produce identical values. Each row is `[bytes, lisplens_file, lisplens_line]`:
  #
  # - `lisplens_file` is the `[path#hash]` that `lisplens line read` prints for a file containing
  #   exactly `bytes` — the 16-hex file-level value.
  # - `lisplens_line` is the `N:hash` it prints for `bytes` as a single line — the 4-hex anchor
  #   truncation, present only for single-line inputs. For the multi-line spans below, the anchor
  #   value is the file hash's low 16 bits by construction (`anchor_hash` = `xxh3_64 & 0xffff`),
  #   which the spec asserts for every row.
  #
  # The expected values are committed; the spec does not shell out to lisplens.
  lisplens_vectors = [
    ["class Foo", "14e3cd4ea38a392d", "392d"],
    ["  def bar(x, y = 1)", "ad641ac7adf2a5c8", "a5c8"],
    ["attr_accessor :name, :email", "5f1f1abfb9b6b3e4", "b3e4"],
    ["#: (Integer) -> Integer", "186b3aa80c7d9873", "9873"],
    ["def double(x)", "b5cbcff040af2519", "2519"],
    ["class Café", "46cfda2c381ea063", "a063"],
    ["", "2d06800538d394c2", "94c2"],
    ["#: (Integer) -> Integer\ndef double(x)", "1d42eaa24cacb81b", nil],
    ["# @rbs return: String\ndef name", "ccc14c59ba2d5a31", nil],
    ["class Foo\n  def bar(x)\n    x + 1\n  end\nend\n", "789ed8ee46573dda", nil]
  ]

  describe ".file_hash" do
    lisplens_vectors.each do |bytes, file_hex, _line_hex|
      it "matches lisplens for #{bytes.inspect}" do
        expect(described_class.file_hash(bytes)).to eq(file_hex)
      end
    end
  end

  describe ".anchor_hash" do
    lisplens_vectors.each do |bytes, file_hex, line_hex|
      it "is the file hash's low 16 bits for #{bytes.inspect}" do
        expect(described_class.anchor_hash(bytes)).to eq(file_hex[-4..])
      end

      next if line_hex.nil?

      it "matches lisplens's printed anchor for #{bytes.inspect}" do
        expect(described_class.anchor_hash(bytes)).to eq(line_hex)
      end
    end
  end

  describe "throughput" do
    # Anchors hash declaration spans and the file hash covers a whole file, so the digest only needs
    # to stay far from the lens's per-file analysis cost. Measured on a generated 500-line Ruby file
    # (~24.7 KB): ~15.6 MB/s (~634 full-file digests/s) — far above the 1 MB/s floor asserted here.
    it "digests a 500-line Ruby file well above 1 MB/s" do
      src = (1..500).map { |i| "def method_#{i}(arg)\n  arg * #{i} + compute_#{i}\nend\n" }.join
      iterations = 200
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      iterations.times { described_class.digest64(src) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      bytes_per_second = src.bytesize * iterations / elapsed
      expect(bytes_per_second).to be > 1_000_000
    end
  end
end
