# rigor-ffi

Core FFI plugin for Rigor ([ADR-30](../../docs/adr/30-rigor-ffi-plugin-shape.md)).
Models `extend FFI::Library` binding declarations, `attach_function` literals, carrier types,
struct layouts, callbacks, nominal pointer typedefs, and `ffx` target compatibility.

## Layout

```text
plugins/rigor-ffi/
├── README.md
├── lib/
│   ├── rigor-ffi.rb
│   └── rigor/plugin/
│       ├── ffi.rb
│       └── ffi/
│           ├── binding_recognizer.rb
│           ├── types.rb
│           ├── target_detector.rb
│           ├── analyzer.rb
│           ├── catalog.rb
│           └── discoverer.rb
├── sig/
│   └── ffi.rbs
└── demo/
    ├── .rigor.dist.yml
    └── demo.rb
```

## Features

- **AST literal walking**: Recognizes `attach_function`, `callback`, `typedef`, `enum`, `bitmask`, and `layout`.
- **25-symbol primitive set**: Type combinator mapping for all standard FFI primitive types.
- **Universal pointer widening**: `:pointer` parameter inputs accept `FFI::Pointer | FFI::MemoryPointer | FFI::AutoPointer | FFI::Buffer | Integer | String | nil`.
- **Nominal pointer typedefs**: Opaque pointer aliases (`_ptr$`, `_handle$`) become nominal types honoring the robustness principle.
- **`ffx` target detection & diagnostics**: Emits `ffx.unsupported-*` diagnostics when compiling for `ffx`.
- **DSL recognizers extension point**: Sub-plugins register custom macro bindings via `ffi_binding_recognizer`.
