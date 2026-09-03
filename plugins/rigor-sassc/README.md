# rigor-sassc

SassC / LibSass binding plugin for Rigor ([ADR-30](../../docs/adr/30-rigor-ffi-plugin-shape.md)).
Models SassC::Native bindings, prefix-stripping DSL, and nominal pointer typedefs (`SassDataContextPtr`, `SassOptionsPtr`, `SassContextPtr`).

## Features

- **Prefix-stripping recognizer**: Automatically recognizes `sass_`-prefixed C functions exposed under stripped Ruby names.
- **Nominal pointer typedefs**: Enforces nominal pointer safety across LibSass contexts.
- **High-level RBS**: Ships bundled RBS definitions for `SassC::Engine` and `SassC::Native`.
