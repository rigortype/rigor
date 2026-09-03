# rigor-ethon

Ethon / Libcurl binding plugin for Rigor ([ADR-30](../../docs/adr/30-rigor-ffi-plugin-shape.md)).
Models `Ethon::Easy`, `Ethon::Multi`, and option catalog dispatching over `libcurl`.

## Features

- **Option-catalog type inference**: Provides dynamic return types for `Ethon::Easy#perform`, `#response_code`, `#total_time`, and response body/headers.
- **High-level RBS**: Ships bundled RBS definitions for `Ethon::Easy`, `Ethon::Multi`, and `Ethon::Curl`.
