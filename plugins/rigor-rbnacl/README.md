# rigor-rbnacl

RbNaCl / Libsodium binding plugin for Rigor ([ADR-30](../../docs/adr/30-rigor-ffi-plugin-shape.md)).
Models `RbNaCl` bindings, `sodium_function` DSL recognizer, and cryptographic carrier types.

## Features

- **DSL recognizer**: Registers `ffi_binding_recognizer :sodium_function` to parse sodium bindings.
- **High-level RBS**: Ships bundled RBS definitions for `RbNaCl::SecretBox`, `RbNaCl::Signatures::Ed25519::SigningKey`, and verify keys.
