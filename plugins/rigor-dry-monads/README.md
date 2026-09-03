# rigor-dry-monads

A lightweight HKT adapter plugin for [dry-monads](https://dry-rb.org/gems/dry-monads/) `Result` and `Maybe` carriers per [ADR-20](../../docs/adr/20-lightweight-hkt.md) Slice 4.

## Features

- Registers the `dry_monads::result` and `dry_monads::maybe` Lightweight HKT tags.
- Provides `dynamic_return` rules for constructor methods (`Success`, `Failure`, `Some`, `None`).
- Resolves unwrapping methods (`value!`, `failure`, `value_or`) directly to carried types.
