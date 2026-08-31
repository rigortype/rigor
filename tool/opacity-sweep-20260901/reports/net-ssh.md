# net-ssh — opacity attribution (2026-09-01)

## Numbers

| metric | value |
| --- | --- |
| files | 97 (0 parse errors) |
| expressions | 19911 |
| precision | 57.25% (constant 6314, nominal 3990, shaped 605, refined 64, bot 426) |
| protection | 34.04% (1181 protected / 2288 unprotected) |
| cause_site_counts | inferred_return_untyped 1235, none 573, unsupported_syntax 475, explicit_untyped 5 |
| tractability | engine_gap 1710, add_rbs 5 |

Opaque split (8512): calls 3700 (precise-receiver 426, implicit-self 1044, dynamic-receiver 2230), local reads 2427 (def_param 1282, block_param 249, assigned_local 896), ivars 217, constants 330 (ConstantPathNode 220 + ConstantReadNode 110), joins/mirrors (LocalVariableWrite 405, EmbeddedStatements 233, If 220, Or 81, And 74) = G.

## Cases

1. **Rest/kwrest params drop the return summary — D, the headline (46+ sites).** `Net::SSH::Buffer.from(*args)` (buffer.rb:46) answers Dynamic at all 46 call sites (e.g. authentication/agent.rb:157) although the body's final `buffer` reads `Net::SSH::Buffer` even in the project env (verified with a project-scope probe). Minimal scratch repro (scratchpad/minisplat): `def self.plain(a)` → precise at call site; `def self.splat(*args)` → Dynamic; `def self.kwsplat(**o)` → Dynamic; a block in the body is innocent; instance methods equally affected (`isplat` → Dynamic, `iplain` → 42). Confirmed ENGINE-WIDE, not lens-only: under `rigor check`, `SpCheck.pln(1).nosuch` fires `undefined method ... for 7` while the `*args` and `**o` twins stay silent. Mechanism: any def whose signature contains `*rest` or `**kwrest` loses its inferred call-site return entirely, independent of the body. Fix direction: bind rest→Array[Dynamic]/kwrest→Hash[Symbol,Dynamic] and keep the body-inferred return instead of bailing. Also hits `send_packet(type, *args)`, `send_and_wait(type, *args)` (implicit-self lane).
2. **OpenSSL RBS not loaded — B, large.** `::OpenSSL::Cipher` reads Dynamic[top] (transport/cipher_factory.rb:28, verified via type-of). 143 `OpenSSL::` references across 29 files; the transport/kex/hmac/cipher/pkey chains all go Dynamic downstream of these constants. Also explains a large slice of the 330 opaque constant reads and of unsupported_syntax (475 — unresolved constants carry that label; every opaque node class here IS in PRISM_DISPATCH, so none of the 475 is a missing node handler). Fix: load stdlib `openssl` (and `socket`/`zlib`) RBS for this config — config `libraries:` or require-detection.
3. **Refined-receiver dispatch fails — D (15+ sites).** `RUBY_PLATFORM == "java"` → Dynamic with receiver typed `non-empty-string` (authentication/certificate.rb:35); scratch repro: `RUBY_PLATFORM == "x"` → Dynamic while `"abc" == "java"` → false. Mechanism: a Refined-tier receiver is not erased to its base class for method lookup, so even String#== misses. Fix: erase Refined→base in MethodDispatcher lookup. Pairs: non-empty-string#== 10, #< 5.
4. **Param-sourced — A (closed).** 1531 param local reads (18% of opaque) plus the param→ivar root `@content = content.to_s` (buffer.rb initialize) feeding the whole `read`/`read_long`/`read_string`/`read_key` family (~35 precise-receiver pair sites) — ADR-58 ivar lane.
5. **Container-of-Dynamic — C (~40 pair sites + 2230 propagation).** Hash[Dynamic,Dynamic]#[]=/#[] (19), Hash[Symbol,Dynamic]#[]= (9), {}#[] / {}#[]= (9), channel `properties` hash (connection/channel.rb:136,141). Roots are A/B.
6. **Proc#[] on a literal proc — D (6 sites).** transport/algorithms.rb:466-472: `key = Proc.new { |salt| digester.digest(...) }; iv_client = key["A"]` → Dynamic. Fix: type Proc#call/#[] from the literal block's inferred return (here rooted in B's OpenSSL digest anyway, but the Proc lane itself answers Dynamic before that matters).
7. **`send` name collision — D (3 sites).** proxy/socks4.rb:54 `socket.send packet, 0` — receiver typed Socket (precise); BasicSocket#send is a real method but the call answers Dynamic (reflection-send handling wins). Fix: when the receiver's class hierarchy defines `send`, dispatch it; reserve reflection handling for Object#send with symbol/string selector args.
8. **Class#send metaprogramming — genuine dynamic (5 sites).** transport/ctr.rb:41 `singleton_class.send(:alias_method, ...)`; also `singleton_class` returns bare `Class`, losing singleton identity (same weakness as faraday's `self.class`).
9. **RESOLVED residue — coverage-lens artifact (G-metric).** `Net::SSH::Buffer#append` (4 sites, agent.rb:227): the jbuilder-phase check matrix explained it — the coverage/protection lens types ANY cross-file user-method call Dynamic (instance and `def self.` alike), while `rigor check` resolves the same summaries (`CrossPlain.new.imeth(1)` cross-file fires `undefined method ... for 42`). append is defined in buffer.rb and called from agent.rb — lens artifact, not an engine gap. The same lens layer sits UNDER many pair counts here (read_* family, CipherFactory.get): after the lens consults project summaries, the read_* family would still be Dynamic (A/@content-rooted) and CipherFactory.get still B (OpenSSL), but append/Buffer.from-style precise returns would surface. Note the splat drop (case 1) is NOT this: it reproduces same-file and in `rigor check` itself.
10. **G joins/mirrors:** ~1013 sites.
