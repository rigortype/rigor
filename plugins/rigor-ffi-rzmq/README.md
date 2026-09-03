# rigor-ffi-rzmq

FFI-RZMQ / ZeroMQ binding plugin for Rigor ([ADR-30](../../docs/adr/30-rigor-ffi-plugin-shape.md)).
Models `ZMQ::Context`, `ZMQ::Socket`, and `LibZMQ` wrapper signatures.

## Features

- **Cross-gem bundled RBS**: Ships curated signatures for `LibZMQ` and higher-level `ZMQ` wrapper types.
- **Socket lifecycle**: Models socket types, flags, and send/recv calls.
