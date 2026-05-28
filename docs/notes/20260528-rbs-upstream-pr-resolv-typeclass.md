# Upstream `ruby/rbs` PR — `Resolv::DNS` typeclass-narrowed return

Coordination handoff for the parallel `/Users/megurine/repo/ruby/rbs`
session preparing the upstream PR. Mastodon analysis cycle (2026-05-28,
789 → 2 errors) leaves one user-facing stdlib RBS gap that the upstream
PR closes; the other gap CURRENT_WORK referenced (`StringScanner#[]`)
turned out to be already-landed upstream.

## 1. `StringScanner#[]` — already upstream, no PR needed

Upstream `stdlib/strscan/0/string_scanner.rbs:501` (HEAD as of
`fcc16851`):

```rbs
def []: (Integer | String | Symbol) -> String?
```

Bundled `rbs-3.10.0` (which Rigor currently ships against) still has
the narrow `(Integer) -> String?` shape, which is why
`signature_parser.rb`'s `scanner[:key]` sites in the Mastodon trial
false-fire. **The fix is a Rigor-side `rbs` gem version bump**, not an
upstream PR. Out of scope for the upstream session.

## 2. `Resolv::DNS#getresources` / `#getresource` / `#each_resource` — typeclass-narrowed return

**The actual PR target.**

### Empirical evidence

Mastodon `app/validators/email_mx_validator.rb:49`:

```ruby
records = dns.getresources(domain, Resolv::DNS::Resource::IN::MX).to_a.map { |e| e.exchange.to_s }
```

`.exchange` is defined on `Resolv::DNS::Resource::MX` (and inherited by
`IN::MX`), **NOT** on the base `Resolv::DNS::Resource`. Current
upstream sig (`stdlib/resolv/0/resolv.rbs:311`):

```rbs
def getresources: (dns_name name, singleton(Resolv::DNS::Query) typeclass) -> Array[Resolv::DNS::Resource]
```

The element type is the upper bound `Resolv::DNS::Resource`, dropping
the typeclass-determined subtype. Any caller passing a specific
subclass (the canonical `dns.getresources(name, IN::MX)` / `IN::A` /
`IN::AAAA` shape — the only practical use) loses precision.

### Sibling methods with the same shape

All in `stdlib/resolv/0/resolv.rbs`, all on class `Resolv::DNS`:

| Line | Method | Surface |
|---:|---|---|
| 302 | `getresource` | returns one `Resource` |
| 311 | `getresources` | returns `Array[Resource]` |
| 221 | `each_resource` | block parameter is `Resource` |
| 223 | `extract_resources` | block parameter is `Resource` |

`fetch_resource` (line 230) accepts a typeclass argument too but does
NOT return / yield a `Resource` — the block yields `(Message, Name)`.
Out of scope.

### Suggested fix — bounded generic method

RBS supports bounded type parameters (precedent: `core/random.rbs:97`
`def rand: ... | [T < Numeric] (::Range[T]) -> T`,
`core/encoding.rbs:136 / :182`, `core/dir.rbs:919`,
`core/kernel.rbs:679 / :1407 / :1449 / :2279`,
`core/marshal.rbs:154`, `core/ractor.rbs:557`), so a single generic
line per method is the cleanest shape:

```rbs
def getresources: [T < Resolv::DNS::Resource] (dns_name name, singleton(T) typeclass) -> Array[T]

def getresource: [T < Resolv::DNS::Resource] (dns_name name, singleton(T) typeclass) -> T

def each_resource: [T < Resolv::DNS::Resource] (dns_name name, singleton(T) typeclass) { (T) -> void } -> void

def extract_resources: [T < Resolv::DNS::Resource] (Resolv::DNS::Message msg, dns_name name, singleton(T) typeclass) { (T) -> void } -> void
```

### Edge case — `Resolv::DNS::Resource::ANY`

`Resolv::DNS::Resource::ANY < Resolv::DNS::Query`
(`stdlib/resolv/0/resolv.rbs:833`) is **NOT** a subclass of
`Resolv::DNS::Resource` — it sits parallel to `Resource` under
`Query`. Passing `ANY` as the typeclass yields a heterogeneous mix of
matching resource types, statically the bare `Resource` envelope. The
bounded `[T < Resolv::DNS::Resource]` parameter excludes `ANY`, so the
old wide overload survives alongside as the fallback:

```rbs
def getresources: [T < Resolv::DNS::Resource] (dns_name name, singleton(T) typeclass) -> Array[T]
                | (dns_name name, singleton(Resolv::DNS::Resource::ANY) typeclass) -> Array[Resolv::DNS::Resource]
```

(Same shape for the three sibling methods.)

### Alternative — per-subclass overloads

If bounded generics produce awkward upstream-test-corpus inference
output, the explicit-overload variant trades verbosity for
predictability. The full set covers the
`Resolv::DNS::Resource::IN::{A, AAAA, CNAME, HINFO, LOC, MINFO, MX, NS, PTR, SOA, SRV, TXT, WKS}`
and `Resolv::DNS::Resource::Generic` subclasses (plus the `ANY`
fallback). ~16 overload lines per method × 4 methods ≈ 64 lines —
not unreasonable, but the generic variant is preferable when it
works.

## Rigor-side coordination

- Rigor does NOT plan to ship a `sig/` overlay or a stdlib-overlay
  plugin for this gap. The decision (see commit message of this note's
  authoring session) is **Option D + A**: defer to upstream + document
  the user-side `signature_paths:` / `# rigor:disable` workaround for
  affected projects in the meantime.
- The Mastodon residue is recorded in
  [`docs/CURRENT_WORK.md`](../CURRENT_WORK.md) under "The 2 remaining
  errors" as the Resolv-side gap.
- Once the upstream PR lands and a new `rbs` gem ships, the Rigor
  bundled `rbs` version bump will close the Mastodon site
  automatically (and the `StringScanner#[]` site at the same time).

## References

- Upstream rbs HEAD examined at commit `fcc16851` (2026-05-28).
- Bundled `rbs-3.10.0` for comparison.
- Mastodon site: `app/validators/email_mx_validator.rb:49`.
- CURRENT_WORK "Stdlib RBS coverage-gap pattern" item.
