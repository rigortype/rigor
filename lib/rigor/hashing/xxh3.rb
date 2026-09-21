# frozen_string_literal: true

module Rigor
  module Hashing
    # Pure-Ruby XXH3-64 (seed 0, default secret) — the content hash for the `rigor lens` anchors of
    # ADR-113 WD6, landed ahead of `rigor lens` itself (#1083). A port of the upstream xxHash scalar
    # path (`xxhash.h`'s `XXH3_64bits` with `XXH3_kSecret`), pinned by the upstream sanity-check
    # vectors and cross-checked against lisplens's `xxhash-rust` output; see
    # `spec/rigor/hashing/xxh3_spec.rb`.
    #
    # Pure Ruby per ADR-31: a native `xxhash` gem is a supply-chain addition to hash a few hundred
    # bytes per call. Only the seedless/default-secret variant is implemented — the `rigor lens`
    # anchors are the sole consumer, and they match lisplens ADR-0008's form exactly:
    #
    # - {.anchor_hash} is `xxh3_64 & 0xffff` printed as 4 lowercase hex digits (a per-row anchor).
    # - {.file_hash} is the full 64-bit value printed as 16 lowercase hex digits (a file-level guard).
    #
    # Every arithmetic op below is modulo 2^64; `& MASK64` marks the spots where the C code wraps.
    module XXH3
      # Constant and helper names keep upstream's `xxhash.h` identifiers (PRIME64_1, accumulate_512,
      # …) so the port stays diffable against the reference scalar path.
      # rubocop:disable Naming/VariableNumber
      MASK64 = (1 << 64) - 1
      MASK32 = (1 << 32) - 1

      PRIME32_1 = 0x9E3779B1
      PRIME32_2 = 0x85EBCA77
      PRIME32_3 = 0xC2B2AE3D
      PRIME64_1 = 0x9E3779B185EBCA87
      PRIME64_2 = 0xC2B2AE3D27D4EB4F
      PRIME64_3 = 0x165667B19E3779F9
      PRIME64_4 = 0x85EBCA77C2B2AE63
      PRIME64_5 = 0x27D4EB2F165667C5
      PRIME_MX1 = 0x165667919E3779F9
      PRIME_MX2 = 0x9FB21C651E98DF25

      STRIPE_LEN = 64
      SECRET_CONSUME_RATE = 8
      ACC_NB = STRIPE_LEN / 8
      MIDSIZE_MAX = 240
      SECRET_SIZE_MIN = 136
      MIDSIZE_STARTOFFSET = 3
      MIDSIZE_LASTOFFSET = 17
      SECRET_LASTACC_START = 7
      SECRET_MERGEACCS_START = 11

      # `XXH3_kSecret` — the 192-byte default secret taken from FARSH, verbatim from `xxhash.h`
      # (one hex pair per upstream byte literal).
      SECRET = [
        "b8fe6c3923a44bbe7c01812cf721ad1cded46de9839097db7240a4a4b7b3671f" \
        "cb79e64eccc0e578825ad07dccff7221b8084674f743248ee03590e6813a264c" \
        "3c2852bb91c300cb88d0658b1b532ea371644897a20df94e3819ef46a9deacd8" \
        "a8fa763fe39c343ff9dcbbc7c70b4f1d8a51e04bcdb45931c89f7ec9d9787364" \
        "eac5ac8334d3ebc3c581a0fffa1363eb170ddd51b7f0da49d316552629d4689e" \
        "2b16be587d47a1fc8ff8b8d17ad031ce45cb3a8f95160428afd7fbcabb4b407e"
      ].pack("H*").freeze

      # XXH3_INIT_ACC
      INIT_ACC = [PRIME32_3, PRIME64_1, PRIME64_2, PRIME64_3, PRIME64_4, PRIME32_2, PRIME64_5, PRIME32_1].freeze

      private_constant :MASK64, :MASK32, :PRIME32_1, :PRIME32_2, :PRIME32_3, :PRIME64_1, :PRIME64_2, :PRIME64_3,
                       :PRIME64_4, :PRIME64_5, :PRIME_MX1, :PRIME_MX2, :STRIPE_LEN, :SECRET_CONSUME_RATE,
                       :ACC_NB, :MIDSIZE_MAX, :SECRET_SIZE_MIN, :MIDSIZE_STARTOFFSET, :MIDSIZE_LASTOFFSET,
                       :SECRET_LASTACC_START, :SECRET_MERGEACCS_START, :SECRET, :INIT_ACC

      class << self
        # XXH3_64bits of `bytes`, hashed as raw bytes — the string's encoding is ignored.
        def digest64(bytes)
          len = bytes.bytesize
          if len <= 16 then len_0to16(bytes, len)
          elsif len <= 128 then len_17to128(bytes, len)
          elsif len <= MIDSIZE_MAX then len_129to240(bytes, len)
          else hash_long(bytes, len)
          end
        end

        # lisplens ADR-0008's `anchor_hash`: the low 16 bits of the digest as 4 lowercase hex digits.
        def anchor_hash(bytes)
          format("%04x", digest64(bytes) & 0xffff)
        end

        # lisplens ADR-0008's `file_hash`: the full digest as 16 lowercase hex digits.
        def file_hash(bytes)
          format("%016x", digest64(bytes))
        end

        private

        # --- short keys: len <= 16 ---

        def len_0to16(bytes, len)
          if len > 8 then len_9to16(bytes, len)
          elsif len >= 4 then len_4to8(bytes, len)
          elsif len.positive? then len_1to3(bytes, len)
          else
            xxh64_avalanche(u64(SECRET, 56) ^ u64(SECRET, 64))
          end
        end

        def len_1to3(bytes, len)
          c1 = bytes.getbyte(0)
          c2 = bytes.getbyte(len >> 1)
          c3 = bytes.getbyte(len - 1)
          combined = (c1 << 16) | (c2 << 24) | c3 | (len << 8)
          bitflip = u32(SECRET, 0) ^ u32(SECRET, 4)
          xxh64_avalanche(combined ^ bitflip)
        end

        def len_4to8(bytes, len)
          input1 = u32(bytes, 0)
          input2 = u32(bytes, len - 4)
          bitflip = u64(SECRET, 8) ^ u64(SECRET, 16)
          keyed = (input2 + (input1 << 32)) ^ bitflip
          rrmxmx(keyed, len)
        end

        def len_9to16(bytes, len)
          bitflip1 = u64(SECRET, 24) ^ u64(SECRET, 32)
          bitflip2 = u64(SECRET, 40) ^ u64(SECRET, 48)
          input_lo = u64(bytes, 0) ^ bitflip1
          input_hi = u64(bytes, len - 8) ^ bitflip2
          acc = (len + swap64(input_lo) + input_hi + mul128_fold64(input_lo, input_hi)) & MASK64
          xxh3_avalanche(acc)
        end

        # --- mid-size keys: 17 <= len <= 240 (mum-hash on 16-byte chunks) ---

        def mix16b(bytes, in_off, sec_off)
          input_lo = u64(bytes, in_off)
          input_hi = u64(bytes, in_off + 8)
          mul128_fold64(input_lo ^ u64(SECRET, sec_off), input_hi ^ u64(SECRET, sec_off + 8))
        end

        def len_17to128(bytes, len)
          acc = len * PRIME64_1
          if len > 32
            if len > 64
              if len > 96
                acc += mix16b(bytes, 48, 96)
                acc += mix16b(bytes, len - 64, 112)
              end
              acc += mix16b(bytes, 32, 64)
              acc += mix16b(bytes, len - 48, 80)
            end
            acc += mix16b(bytes, 16, 32)
            acc += mix16b(bytes, len - 32, 48)
          end
          acc += mix16b(bytes, 0, 0)
          acc += mix16b(bytes, len - 16, 16)
          xxh3_avalanche(acc & MASK64)
        end

        def len_129to240(bytes, len)
          acc = len * PRIME64_1
          nb_rounds = len / 16
          8.times { |i| acc += mix16b(bytes, 16 * i, 16 * i) }
          acc_end = mix16b(bytes, len - 16, SECRET_SIZE_MIN - MIDSIZE_LASTOFFSET)
          acc = xxh3_avalanche(acc & MASK64)
          (8...nb_rounds).each do |i|
            acc_end += mix16b(bytes, 16 * i, (16 * (i - 8)) + MIDSIZE_STARTOFFSET)
          end
          xxh3_avalanche((acc + acc_end) & MASK64)
        end

        # --- long keys: len > 240 (striped accumulate + scramble, then merge) ---

        def hash_long(bytes, len)
          acc = INIT_ACC.dup
          secret_size = SECRET.bytesize
          nb_stripes_per_block = (secret_size - STRIPE_LEN) / SECRET_CONSUME_RATE
          block_len = STRIPE_LEN * nb_stripes_per_block
          nb_blocks = (len - 1) / block_len

          nb_blocks.times do |n|
            accumulate_stripes(acc, bytes, n * block_len, nb_stripes_per_block)
            scramble(acc, secret_size - STRIPE_LEN)
          end

          last_off = nb_blocks * block_len
          accumulate_stripes(acc, bytes, last_off, (len - 1 - last_off) / STRIPE_LEN)
          accumulate_512(acc, bytes, len - STRIPE_LEN, secret_size - STRIPE_LEN - SECRET_LASTACC_START)

          merge_accs(acc, len * PRIME64_1)
        end

        def accumulate_stripes(acc, bytes, base_off, nb_stripes)
          nb_stripes.times do |s|
            accumulate_512(acc, bytes, base_off + (s * STRIPE_LEN), s * SECRET_CONSUME_RATE)
          end
        end

        # XXH3_accumulate_512_scalar: each 64-byte stripe folds into the 8-lane accumulator — the
        # data value is added to the swapped adjacent lane, and the secret-keyed value contributes a
        # 32x32->64 product to its own lane.
        def accumulate_512(acc, bytes, in_off, sec_off)
          ACC_NB.times do |i|
            data_val = u64(bytes, in_off + (8 * i))
            data_key = data_val ^ u64(SECRET, sec_off + (8 * i))
            acc[i ^ 1] = (acc[i ^ 1] + data_val) & MASK64
            acc[i] = (acc[i] + ((data_key & MASK32) * (data_key >> 32))) & MASK64
          end
        end

        # XXH3_scrambleAcc_scalar
        def scramble(acc, sec_off)
          ACC_NB.times do |i|
            acc[i] = ((acc[i] ^ (acc[i] >> 47) ^ u64(SECRET, sec_off + (8 * i))) * PRIME32_1) & MASK64
          end
        end

        # XXH3_mergeAccs over the default secret, at SECRET_MERGEACCS_START.
        def merge_accs(acc, start)
          result = start
          4.times do |i|
            result += mul128_fold64(acc[2 * i] ^ u64(SECRET, SECRET_MERGEACCS_START + (16 * i)),
                                    acc[(2 * i) + 1] ^ u64(SECRET, SECRET_MERGEACCS_START + (16 * i) + 8))
          end
          xxh3_avalanche(result & MASK64)
        end

        # --- primitives ---

        def u32(bytes, off) = bytes.unpack1("L<", offset: off)

        def u64(bytes, off) = bytes.unpack1("Q<", offset: off)

        def swap64(value) = [value].pack("Q>").unpack1("Q<")

        def rotl64(value, shift) = ((value << shift) | (value >> (64 - shift))) & MASK64

        def mul128_fold64(lhs, rhs)
          product = lhs * rhs
          (product & MASK64) ^ (product >> 64)
        end

        # XXH3_avalanche — the fast finalizer used when the input is already partially mixed.
        def xxh3_avalanche(hash)
          hash = (hash ^ (hash >> 37)) & MASK64
          hash = (hash * PRIME_MX1) & MASK64
          hash ^ (hash >> 32)
        end

        # XXH64_avalanche — the stronger finalizer for the shortest keys.
        def xxh64_avalanche(hash)
          hash ^= hash >> 33
          hash = (hash * PRIME64_2) & MASK64
          hash ^= hash >> 29
          hash = (hash * PRIME64_3) & MASK64
          hash ^ (hash >> 32)
        end

        # XXH3_rrmxmx — the len 4-8 finalizer (Pelle Evensen's mix).
        def rrmxmx(hash, len)
          hash = (hash ^ rotl64(hash, 49) ^ rotl64(hash, 24)) & MASK64
          hash = (hash * PRIME_MX2) & MASK64
          hash ^= (hash >> 35) + len
          hash = (hash * PRIME_MX2) & MASK64
          hash ^ (hash >> 28)
        end
      end
      # rubocop:enable Naming/VariableNumber
    end
  end
end
