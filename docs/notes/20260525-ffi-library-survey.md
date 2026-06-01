# FFI library usage survey — feeding `rigor-ffi` design (2026-05-25)

Status: **research note, no design commitments.**

Prerequisite for a future
`rigor-ffi` plugin that should make FFI-binding gems statically analysable
to the level required by [ADR-0](../adr/0-concept.md) /
[ADR-1](../adr/1-types.md) and the [robustness
principle](../type-specification/robustness-principle.md).

The end goal is **type-checking Ruby code that *uses* these gems** —
i.e. user code calling `Ethon::Easy#perform`, `RbNaCl::SecretBox#encrypt`,
`ZMQ::Context#socket`, etc. The intermediate goal (the FFI plugin) is
the static substrate that lets that code's type information flow through
the FFI boundary without resorting to wholesale `Dynamic[Top]`.

Sources were read via shallow clones in `/tmp/ffi-survey/<lib>/`; the
clones are not committed and are not referenced as submodules. Citations
point at the clones' file paths so a future reader can re-clone to
verify.

Five libraries surveyed, deliberately spanning the design space:

| Library | Binding style | Purpose |
| --- | --- | --- |
| [ethon](https://github.com/typhoeus/ethon) | Pure FFI | libcurl bindings (the typhoeus engine) |
| [rbnacl](https://github.com/RubyCrypto/rbnacl) | Pure FFI + custom DSL wrapper | libsodium / NaCl cryptography |
| [ffi-rzmq](https://github.com/chuckremes/ffi-rzmq) | Pure FFI **(across gem boundary — ffi-rzmq-core)** | ZeroMQ bindings |
| [childprocess](https://github.com/enkessler/childprocess) | **No FFI** (Ruby `Process` / IO only) | cross-platform child-process control |
| [sassc-ruby](https://github.com/sass/sassc-ruby) | Pure FFI + vendored C source build | libsass bindings |

childprocess is included as a deliberate **negative case** — a gem one
might assume uses FFI that in fact doesn't. It validates that
`rigor-ffi` should activate on the *presence of FFI binding code*, not
on "this gem talks to the OS".

Each section answers the same ten questions so the per-library findings
can be cross-read. The aggregated assessment (decision shape for the
plugin) lives in the closing section.

---

## ethon — libcurl bindings

### 1. FFI module organization

Five files under `lib/ethon/`:

- `curl.rb` — top-level `Ethon::Curl` module, extends `FFI::Library`,
  mixes in the catalogue modules (`curl.rb:9-30`).
- `curls/settings.rb` — five `callback` declarations + the `ffi_lib`
  target.
- `curls/functions.rb` — every `attach_function` call.
- `curls/classes.rb` — `FFI::Struct` / `FFI::Union` definitions.
- `libc.rb` — minimal libc shim for `select(2)` and `getdtablesize`.

**~32 `attach_function` calls total** (29 libcurl + 2 libc + 1 select).

### 2. `ffi_lib` target

`ffi_lib ['libcurl', 'libcurl.so.4']` (`curls/settings.rb:10`). Platform
shim for `select` chooses `ws2_32` on Windows vs `FFI::Library::LIBC`
elsewhere (`curls/functions.rb:48-52`). No env-var or
`Gem::Util.find_library` resolution.

### 3. typedef usage

No explicit `typedef` calls — FFI built-ins (`:size_t`, `:time_t`,
`:suseconds_t`, `:long_long`, `:int64`) are used directly. Custom names
are introduced as **enum names**, not typedefs (see §7).

### 4. `attach_function` patterns

Three representative shapes (`curls/functions.rb`):

```ruby
# (a) plain return-pointer
base.attach_function :easy_init, :curl_easy_init, [], :pointer  # :15

# (b) enum + varargs
base.attach_function :easy_setopt, :curl_easy_setopt,
  [:pointer, :easy_option, :varargs], :easy_code              # :18

# (c) pointer-to-struct return via .ptr syntax
base.attach_function :version_info, :curl_version_info, [],
  Curl::VersionInfoData.ptr                                    # :42
```

Error wrapping lives in the **Ruby layer**, not the FFI boundary —
e.g. `curl.rb:61` raises if `global_init` returns non-zero.

### 5. Callback definitions

Five callback typedefs (`curls/settings.rb:4-8`):

```ruby
callback :callback,          [:pointer, :size_t, :size_t, :pointer], :size_t
callback :socket_callback,   [:pointer, :int, :poll_action, :pointer, :pointer], :multi_code
callback :timer_callback,    [:pointer, :long, :pointer], :multi_code
callback :debug_callback,    [:pointer, :debug_info_type, :pointer, :size_t, :pointer], :int
callback :progress_callback, [:pointer, :long_long, :long_long, :long_long, :long_long], :int
```

Ruby `Proc`s are stored on the wrapping object and passed straight to
`easy_setopt` (`easy/callbacks.rb:23, :38-44`). FFI does the bridge.

### 6. `FFI::Struct` / `Union` usage

Four carriers in `classes.rb`:

- `MsgData` (`Union`, `:5-7`) — `:whatever, :pointer / :code, :easy_code`.
- `Msg` (`Struct`, `:10-12`) — `:code, :msg_code, :easy_handle, :pointer, :data, MsgData`.
- `VersionInfoData` (`Struct`, `:14-24`) — runtime version metadata.
- `FDSet` (`Struct`, `:27-52`) — platform-conditional layout (Windows vs POSIX).
- `Timeval` (`Struct`, `:55-62`) — likewise.

No `ManagedStruct`, no `BitStruct`. `FDSet` is the only platform-branched
layout.

### 7. enum usage

Heavy use of `FFI::Library#enum` (`constants.rb:17-78`):

```ruby
EasyCode        = enum(:easy_code, easy_codes)
EasyOption      = enum(:easy_option, easy_options(:enum).to_a.flatten)
PollAction      = enum(:poll_action, [:none, :in, :out, :inout, :remove])
SocketReadiness = bitmask(:socket_readiness, [:in, :out, :err])
```

Catalogues come from `Ethon::Curls::Codes`, `Options`, `Infos` —
plain Ruby modules that return arrays of symbols.

### 8. Pointer / `MemoryPointer` / `AutoPointer` wrapping

**`FFI::AutoPointer` is the primary lifecycle pattern**
(`easy/operations.rb:14`, `multi/operations.rb:17`):

```ruby
@handle ||= FFI::AutoPointer.new(Curl.easy_init, Curl.method(:easy_cleanup))
```

Explicit `MemoryPointer.new(:long)` / `Curl::Timeval.new` for in/out
parameters during the multi-loop. Procs are stashed in a `@procs` hash
to keep them GC-rooted (`easy/options.rb:42-45`).

### 9. User-facing Ruby API → FFI mapping

`Easy#url=` is the canonical bridge (`easy/options.rb:10-13`):

```ruby
def url=(value)
  @url = value
  Curl.set_option(:url, value, handle)
end
```

`Curl.set_option` (`curls/options.rb:13-109`) dispatches on the
option-catalogue's `:type` field and calls `easy_setopt(handle,
const, va_type, value)` via varargs. Each option's `:type`
(`:string` / `:long` / `:callback` / `:string_as_pointer`) is the
*runtime* type discriminator.

### 10. Static-expandability assessment

Recoverable: FFI signatures (load-time), struct layouts, all five
callback typedefs, enum symbol→int mappings (from the catalogue
modules).

Not recoverable without modelling the option dispatcher:

- **Varargs in `easy_setopt`** — the third argument's FFI type is
  determined by the option enum value, via the catalogue. A naive
  walker sees `[:pointer, :easy_option, :varargs]` and shrugs.
- **`define_method` over the option catalogue** (`easy/options.rb:32-47`)
  — every setter (`url=`, `ssl_verifypeer=`, `writefunction`) is
  generated at load time by iterating `Curl.easy_options(nil)`. The
  setters don't exist in the AST.

For rigor-ffi, modelling the option catalogue + generated setters is
the main precision lever beyond stock FFI binding awareness.

---

## rbnacl — libsodium / NaCl bindings

### 1. FFI module organization

Per-primitive split — one module per crypto construction
(`SecretBoxes::XSalsa20Poly1305`, `Signatures::Ed25519`,
`Hash::{SHA256, SHA512, Blake2b}`, `HMAC::*`, `AEAD::*`,
`PasswordHash::Argon2`, `OneTimeAuths::Poly1305`, …). Each module
`extend Sodium` to inherit the FFI machinery
(`lib/rbnacl/sodium.rb:6-66`).

**~52 attach-equivalent calls total**, the majority via a custom DSL
wrapper `sodium_function` rather than raw `attach_function`.

### 2. `ffi_lib` target

```ruby
ffi_lib ["sodium", "libsodium.so.18", "libsodium.so.23", "libsodium.so.26"]
```

A static fallback list spanning ABI versions (`init.rb:8` and again in
`sodium.rb:11` for late-`extend`ed modules). Version check at
`sodium/version.rb:22-25` raises on libsodium < 0.4.3; feature gates
(e.g. Argon2 at `lib/rbnacl.rb:81`) conditionally `require` files based
on the detected version.

### 3. typedef usage

None. Primitive FFI types (`:pointer`, `:ulong_long`, `:size_t`,
`:uint{8,32,64}`, `:string`, `:int`) used directly throughout.

### 4. `attach_function` patterns — the custom-DSL wrapper

**Critical static-analysis hazard.** `sodium_function`
(`sodium.rb:47-55`) wraps `attach_function` in a `module_eval` of an
interpolated heredoc:

```ruby
def sodium_function(name, function, arguments)
  module_eval <<-RUBY, __FILE__, __LINE__ + 1
  attach_function #{function.inspect}, #{arguments.inspect}, :int
  def self.#{name}(*args)
    ret = #{function}(*args)
    ret == 0
  end
  RUBY
end
```

Three properties matter for `rigor-ffi`:

- **Return type is implicit** — every `sodium_function` returns
  `:int` at the FFI layer and `true|false` at the Ruby layer.
- **Arguments are quoted symbols** in a heredoc, not real
  `attach_function` call nodes — a walker that grep-scans for
  `attach_function` will miss them entirely.
- **Two names** — the C function (`:crypto_secretbox_xsalsa20poly1305`)
  and the Ruby method (`:secretbox_xsalsa20poly1305`) — are both
  argument literals.

Representative call site
(`secret_boxes/xsalsa20poly1305.rb:32-38`):

```ruby
sodium_function :secretbox_xsalsa20poly1305,
                :crypto_secretbox_xsalsa20poly1305,
                %i[pointer pointer ulong_long pointer pointer]
```

This pattern is rbnacl's overwhelmingly dominant binding shape. A
companion DSL `sodium_constant` (`sodium.rb:32-45`) does the same trick
for `KEYBYTES` / `NONCEBYTES` / … constants.

### 5. Callback definitions

None. libsodium has no callbacks in its API surface.

### 6. `FFI::Struct` usage

Four streaming-hash state structs (`HMAC::SHA256::State`,
`HMAC::SHA512::State`, `HMAC::SHA512256::State`, `Hash::Blake2b::State`).
Representative (`hmac/sha256.rb:95-106`):

```ruby
class SHA256State < FFI::Struct
  layout :state, [:uint32, 8],
         :count, :uint64,
         :buf,   [:uint8, 64]
end
```

No `ManagedStruct`, `Union`, or `BitStruct`.

### 7. enum usage

None.

### 8. Pointer / `MemoryPointer` / buffer wrapping

rbnacl deliberately **avoids `MemoryPointer`** — buffers are plain
Ruby `String`s in BINARY encoding. The utility is `Util.zeros(n)`
(`util.rb:22-27`):

```ruby
def zeros(n = 32)
  zeros = "\0" * n
  zeros.respond_to?(:force_encoding) ? zeros.force_encoding("ASCII-8BIT") : zeros
end
```

FFI auto-coerces `String` → `:pointer` at call time. Validation goes
through `Util.check_string` / `Util.check_length` (`util.rb:111-117`).

### 9. User-facing Ruby API → FFI mapping

`SecretBox#box` is canonical
(`secret_boxes/xsalsa20poly1305.rb:49-76`):

```ruby
def box(nonce, message)
  Util.check_length(nonce, nonce_bytes, "Nonce")
  msg = Util.prepend_zeros(ZEROBYTES, message)
  ct  = Util.zeros(msg.bytesize)
  success = self.class.secretbox_xsalsa20poly1305(ct, msg, msg.bytesize, nonce, @key)
  raise CryptoError, "Encryption failed" unless success
  Util.remove_zeros(BOXZEROBYTES, ct)
end
alias encrypt box
```

Five-step bridge: validate length → zero-pad → allocate output as a
`String` → call the `sodium_function`-generated wrapper → strip
padding. The user surface is `(String, String) -> String`; nothing in
the FFI types informs that.

### 10. Static-expandability assessment

Recoverable, **if the plugin understands `sodium_function`** as
a binding-defining macro:

- Each `sodium_function(ruby_name, c_name, arg_types)` produces an
  `attach_function c_name, arg_types, :int` + a `self.{ruby_name}` method
  returning Boolean.
- Each `sodium_constant(...)` produces an `attach_function`-derived
  constant.

Not recoverable from the AST alone (i.e. without DSL awareness):

- The generated `attach_function` and `def self.…` (live inside an
  interpolated heredoc string, not as call nodes).
- Conditional feature loading (`rbnacl.rb:81`) — gates entire crypto
  primitives on runtime version detection.

rbnacl is the single strongest argument for the `rigor-ffi` plugin to
support **plugin-side DSL recognisers** — a `sodium_function`-aware
extension that synthesises the same binding facts a literal
`attach_function` would.

---

## ffi-rzmq — ZeroMQ bindings

### 1. FFI module organization

**The FFI bindings live in a separate gem** —
[ffi-rzmq-core](https://github.com/chuckremes/ffi-rzmq-core), declared
as a runtime dependency (`ffi-rzmq.gemspec:24`) and `require`d at
`lib/ffi-rzmq.rb:66`. The `ffi-rzmq` codebase itself
(~1642 lines across `Context`, `Socket`, `Message`, `Poller`,
`PollItem`, `Device`, `Util`, exception classes) is a pure Ruby
**wrapper** over `LibZMQ.*` from the core gem.

This is the **cross-gem boundary case** for FFI analysis.

### 2. `ffi_lib` target

Opaque to ffi-rzmq — handled in ffi-rzmq-core. The README
(`README.rdoc:167-170`) instructs users to install libzmq through their
OS package manager / Homebrew.

### 3. typedef usage

`:size_t` referenced (`socket.rb:531`); custom typedefs would be in
ffi-rzmq-core.

### 4. `attach_function` patterns

Not in ffi-rzmq. The wrapper uses raw `LibZMQ.*` calls with the
"negative return = error, fetch via `LibZMQ.zmq_errno`" idiom
(`util.rb:71-78`):

```ruby
rc = LibZMQ.zmq_setsockopt @socket, name, pointer, length
ZMQ::Util.error_check 'zmq_setsockopt', rc
```

### 5. Callback definitions

`LibC::Free` is passed as a `zmq_msg_init_data` destructor
(`message.rb:134`). Finalizers use `ObjectSpace.define_finalizer` with
closures that call `LibZMQ.zmq_close` / `zmq_ctx_term`
(`context.rb:132`, `socket.rb:580-583`).

### 6. `FFI::Struct` usage

`LibZMQ::PollItem` (defined in ffi-rzmq-core, referenced at
`poll_item.rb:11`, `poll_items.rb:13`). `zmq_msg_t` is wrapped opaquely
as `FFI::MemoryPointer.new(Message.msg_size, 1, false)`
(`message.rb:99`) without a `Layout`.

### 7. enum usage

**None.** Socket types (`ZMQ::REQ = 3`, `ZMQ::REP = 4`, …) and
option keys (`ZMQ::RCVMORE`, `ZMQ::LINGER`, …) are plain Ruby
constants. Option dispatch goes through three arrays —
`IntegerSocketOptions`, `LongLongSocketOptions`,
`StringSocketOptions` (`socket.rb:569-571`) — built once at
load-time.

### 8. Pointer / `MemoryPointer` / buffer wrapping

Finalizer-based lifecycle: every context / socket registers a
`define_finalizer` that calls the corresponding `zmq_*` cleanup
function, **gated on `Process.pid == pid`** to avoid double-close
after fork. Option buffers are either `LibC.malloc`/`free`
(`socket.rb:129, 145`) or cached `FFI::MemoryPointer`s
(`socket.rb:537-547`).

### 9. User-facing Ruby API → FFI mapping

`ZMQ::Context#socket(type)` (`context.rb:109-118`) delegates to
`Socket.new(@context, type)` (`socket.rb:65-88`), which calls
`LibZMQ.zmq_socket` and stores the resulting pointer. The user-facing
**type discriminator is the integer constant `type`**, not a Symbol
(no `:REQ` shorthand).

`Socket#send_string` (`socket.rb:244-247`) wraps the String in a
`Message`, which allocates a `zmq_msg_t` and copies the bytes.

### 10. Static-expandability assessment

Hard problem: ffi-rzmq's signatures live across a gem boundary. A
`rigor-ffi` plugin scanning only the user's project won't see
`LibZMQ.zmq_socket`'s arity / return type unless it can:

- Walk into the ffi-rzmq-core gem's source (cf. [ADR-10](../adr/10-dependency-source-inference.md)
  opt-in dependency-source inference), or
- Ship a bundled RBS for `LibZMQ` (cf. [ADR-25](../adr/25-plugin-contributed-rbs.md)
  plugin-contributed RBS).

Additional precision blockers:

- `:receiver_class` polymorphism in `Socket.new` (`socket.rb:32, 68`)
  — `recvmsg` returns the user's chosen class, defaulting to
  `ZMQ::Message`.
- Version-conditional FFI between ZeroMQ 3.2.x and 4.x — handled
  inside ffi-rzmq-core, invisible at the wrapper layer.
- Dynamic option dispatch via the three arrays at `socket.rb:569-571`.

The natural rigor-ffi shape is: scan ffi-rzmq-core's `attach_function`
calls as a dependency, then type ffi-rzmq's wrapper class methods over
those signatures.

---

## childprocess — the deliberate negative case

### Finding: **uses no FFI at all.**

No `require 'ffi'`, no FFI dependency in `childprocess.gemspec`,
zero `attach_function` / `callback` / `FFI::Struct` calls.

Architecture: platform-dispatcher in `childprocess.rb:17-25` picks
`Unix::Process` or `Windows::Process`, both of which delegate to
Ruby's built-in `::Process.spawn` / `::Process.waitpid2` /
`::Process.kill`. Windows fallback for `SIGKILL` is a shell-out to
`taskkill /F /T /PID` (`process_spawn_process.rb:117-123`). Pipes use
`::IO.pipe`.

### Implication for `rigor-ffi`

childprocess validates that the plugin must activate on **detected FFI
binding code** (`require 'ffi'` + `extend FFI::Library` + at least one
`attach_function` or equivalent), not on "this gem looks low-level".
A gem using Ruby's `Process` / `IO` standard library is core-Ruby's
problem, not the FFI plugin's.

---

## sassc-ruby — vendored libsass via FFI

### 1. FFI module organization

Pure FFI despite the gem advertising a C extension. `sassc.gemspec:27`
declares `spec.extensions = ["ext/extconf.rb"]`, but the extension is
not a `rb_define_method` C extension — `extconf.rb` (`:59-64`)
compiles the vendored libsass submodule into a plain shared library
(`libsass.{bundle,so}`) that is then **loaded via FFI** at runtime
(`lib/sassc/native.rb:9-14`):

```ruby
dl_ext = RbConfig::MAKEFILE_CONFIG['DLEXT']
begin
  ffi_lib File.expand_path("libsass.#{dl_ext}", __dir__)
rescue LoadError
  ffi_lib File.expand_path("libsass.#{dl_ext}", "#{__dir__}/../../ext")
end
```

Three sub-modules under `lib/sassc/native/`:
`native_context_api.rb`, `native_functions_api.rb`,
`sass2scss_api.rb`.

### 2. Library target

Vendored libsass under `ext/libsass` (submodule). Built at gem-install
time; loaded at runtime via the path above. No system-libsass fallback.

### 3. Type aliases (typedef)

Most extensive `typedef` use of the surveyed gems
(`lib/sassc/native.rb:18-29`). Ten opaque-pointer aliases:
`:sass_options_ptr`, `:sass_context_ptr`,
`:sass_file_context_ptr`, `:sass_data_context_ptr`,
`:sass_value_ptr`, `:sass_import_list_ptr`,
`:sass_import_ptr`, `:sass_importer`,
`:sass_c_function_list_ptr`, `:sass_c_function_callback_ptr`.

All resolve to `:pointer` but provide **nominal distinctions** — the
best static-analysis hook in the surveyed corpus.

### 4. `attach_function` patterns

Standard, plus a **prefix-stripping convention** —
`attach_function` is overridden (`lib/sassc/native.rb:39-47`) to
register `sass_make_options` as `Native.make_options`. Examples
(`native_context_api.rb:9, 24, 44, 106`):

```ruby
attach_function :sass_make_options,         [],                        :sass_options_ptr
attach_function :sass_compile_file_context, [:sass_file_context_ptr],  :int
attach_function :sass_delete_data_context,  [:sass_data_context_ptr],  :void
attach_function :sass_option_set_output_style,
                [:sass_options_ptr, SassOutputStyle], :void
```

### 5. Callback definitions

Two typedefs (`lib/sassc/native.rb:31-32`):

```ruby
callback :sass_c_function,        [:pointer, :pointer], :pointer
callback :sass_c_import_function, [:pointer, :pointer, :pointer], :pointer
```

User-supplied Ruby Procs are wrapped via `FFI::Function.new`
(`functions_handler.rb:23-26`, `import_handler.rb:26-33`). The Proc
is stashed in `@callbacks` to keep the wrapper alive.

### 6. `FFI::Struct` usage

Tagged-union of Sass values is the largest layout
(`lib/sassc/native/sass_value.rb:84-95`):

```ruby
class SassValue
  layout :unknown, SassUnknown,
         :boolean, SassBoolean,
         :number,  SassNumber,
         :color,   SassColor,
         :string,  SassString,
         :list,    SassList,
         :map,     SassMap,
         :null,    SassNull,
         :error,   SassError,
         :warning, SassWarning
end
```

Each variant carries its own `SassTag` discriminant (`:33-37` etc.).

### 7. enum usage

Three enums (`sass_output_style.rb:5-10`, `sass_value.rb:7-22`):

```ruby
SassOutputStyle = enum(:sass_style_nested, :sass_style_expanded,
                       :sass_style_compact, :sass_style_compressed)
SassTag         = enum(:sass_boolean, :sass_number, :sass_color, :sass_string,
                       :sass_list, :sass_map, :sass_null, :sass_error, :sass_warning)
SassSeparator   = enum(:sass_comma, :sass_space)
```

Used directly in `attach_function` argument lists, so FFI auto-converts
Ruby Symbols at the call site.

### 8. Pointer / `MemoryPointer` / lifecycle wrapping

Two notable patterns:

- **String input → FFI ownership transfer**
  (`lib/sassc/native.rb:54-58`):

  ```ruby
  def self.native_string(string)
    m = FFI::MemoryPointer.from_string(string)
    m.autorelease = false
    m
  end
  ```

  `autorelease = false` hands the buffer to libsass, which frees it.

- **`ensure`-block lifecycle**
  (`lib/sassc/engine.rb:63`) — `Native.delete_data_context(data_context)`
  in the rescue/ensure tail of `Engine#render`.

No `AutoPointer`.

### 9. User-facing Ruby API → FFI mapping

`SassC::Engine#render` (`lib/sassc/engine.rb:22-64`) is a straight
eight-step FFI pipeline: `make_data_context` → unwrap to context →
unwrap to options → call ~10 `option_set_*` setters → register
callbacks → `compile_data_context` → extract output strings → free.
No metaprogramming — every step is a literal `Native.something` call.

### 10. Static-expandability assessment

The **best-behaved** library in the survey from `rigor-ffi`'s
perspective:

- All `attach_function` calls are literal call nodes.
- Typedef'd opaque pointers give every C resource a distinct nominal
  type; a plugin can carry `sass_data_context_ptr` as
  `Nominal[SassC::Native::SassDataContextPtr]` and refuse mixing.
- Enums are statically enumerated.
- Struct layouts are statically declared.

The remaining gaps are not FFI-specific:

- `FFI::Function.new` callbacks (`functions_handler.rb:23-26`) are
  anonymous Procs whose internal Ruby calls require ordinary flow
  analysis.
- No `.rbs` stub file — the FFI declarations are the only contract.

---

## Aggregated findings

### Binding-style taxonomy

| Pattern | Libraries | Static-analysability |
| --- | --- | --- |
| Literal `attach_function` calls | ethon, sassc-ruby | High |
| Custom DSL wrapping `attach_function` (e.g. `sodium_function`) | rbnacl | Low without DSL awareness |
| Bindings in a **separate gem** (`ffi-rzmq-core`) | ffi-rzmq | Low without dependency-source inference |
| No FFI at all (uses Ruby `Process`/`IO`) | childprocess | N/A |

### Recurring FFI primitives the plugin must understand

- `extend FFI::Library` + `ffi_lib`
- `attach_function name, c_name, [arg_types], return_type` — straight
  and with the trailing options Hash (`:blocking`, `:enums`)
- `callback name, [arg_types], return_type`
- `typedef existing_type, alias_name` — chiefly as **nominal
  pointer aliases** (sassc-ruby pattern)
- `enum :name, [:a, :b, …]` and `bitmask` (ethon, sassc-ruby)
- `FFI::Struct`, `FFI::Union`, `FFI::ManagedStruct`,
  `FFI::AutoPointer`
- `FFI::MemoryPointer.{new, from_string}`,
  `MemoryPointer#put_bytes / read_string`
- `FFI::Pointer.{null?, address}`, `FFI::Pointer::NULL`
- `FFI::Function.new(return, [args]) { |…| … }` — anonymous callbacks
- The String ↔ `:pointer` / `:string` auto-coercion at call boundary

### Cross-cutting hazards for static inference

1. **DSL wrappers around `attach_function`** (rbnacl's
   `sodium_function`, sassc-ruby's overridden `attach_function` for
   prefix stripping). The plugin needs **DSL recognisers** that
   replay the binding fact a literal `attach_function` would have
   recorded. This maps cleanly onto [ADR-16](../adr/16-macro-expansion.md)
   Tier C (heredoc-template expansion) for `sodium_function` and
   Tier B (trait inlining) for the prefix-stripping override.

2. **Cross-gem binding definitions** (ffi-rzmq → ffi-rzmq-core). Two
   plausible answers, both already in the roadmap:
   - **Plugin-contributed RBS** ([ADR-25](../adr/25-plugin-contributed-rbs.md))
     — ship a hand-curated `LibZMQ` stub inside `rigor-ffi-rzmq`.
   - **Dependency-source inference** ([ADR-10](../adr/10-dependency-source-inference.md))
     — opt-in walk of `ffi-rzmq-core`'s `attach_function` calls.

   ADR-25 is the lower-FP path; ADR-10 is the lower-maintenance one.

3. **Varargs dispatched by enum** (ethon's `easy_setopt`). The
   `va_type` is determined by the second argument's enum value through
   an external catalogue. Without modelling the option dispatcher the
   third argument types as `Dynamic[Top]`; with the catalogue it
   types as a small union per option. Likely too much per-library
   special-casing to belong in `rigor-ffi` core — fits better as
   per-library plugins (`rigor-ethon`, `rigor-rbnacl`) on top.

4. **Dynamic method generation from FFI metadata** (ethon's
   `define_method` over the option catalogue at
   `easy/options.rb:32-47`). The generated setters / getters don't
   exist in the AST. This is the same problem ADR-16 Tier B / C
   solves for Devise / dry-struct.

5. **Typedef'd opaque pointers as nominal types**. Only sassc-ruby
   uses this heavily, but it's the *cleanest* hook — a typedef
   `:sass_data_context_ptr` should become
   `Nominal[SassC::Native::SassDataContextPtr]` and never silently
   unify with a bare `:pointer`. This is also the strongest
   robustness-principle alignment in the survey: returns are strict
   (the typed alias), inputs accept either the alias or a base
   `:pointer`.

6. **Anonymous callback Procs**
   (`FFI::Function.new(rt, [args]) { … }`). The block body wants the
   ordinary inference engine, with the `callback` typedef binding the
   block's parameter types. Implementation-wise the closest analogue
   is the [ADR-28](../adr/28-path-scoped-protocol-contracts.md)
   binder-tier mechanism for parameter substitution.

7. **Resource lifecycle**. `AutoPointer.new(ctor, dtor_method)`,
   `ObjectSpace.define_finalizer`, `ensure` blocks calling a
   `delete_*` function. None of these are *type* problems on their
   own; they only matter if the plugin grows a use-after-free /
   double-free diagnostic family. Out of scope for the initial
   `rigor-ffi`.

### Suggested `rigor-ffi` shape (first cut, not a design commitment)

What the **core plugin** should ship (covers ethon + sassc-ruby + 80 %
of any vanilla FFI gem):

- Recognise `extend FFI::Library` and treat the host module as the
  binding registry.
- Walk `attach_function`, `callback`, `typedef`, `enum`, `bitmask`,
  `FFI::Struct.layout`, `FFI::Union.layout` calls and contribute
  facts (method signatures, callback types, enum symbol sets, struct
  field offsets and types) to the engine.
- Type the well-known FFI carriers — `FFI::Pointer`,
  `FFI::MemoryPointer`, `FFI::Buffer`, `FFI::AutoPointer`,
  `FFI::Function`, `FFI::Struct`/`Union` subclasses — with precise
  method signatures (`read_string : (?Integer) -> String`,
  `put_bytes : (Integer, String, ?Integer, ?Integer) -> self`, etc.).
- Model the **String ↔ `:string` / `:pointer` coercion** at call
  boundary so `LibZMQ.zmq_send(socket, "hello", 5, 0)` doesn't error.
- Treat typedef'd pointer aliases as **distinct nominals**, with the
  base `:pointer` accepted as a subtype on input only (robustness).

What belongs in **per-library sub-plugins** (`rigor-rbnacl`,
`rigor-ethon`, `rigor-ffi-rzmq`, `rigor-sassc`):

- DSL recognisers (`sodium_function`, sassc-ruby's prefix-strip
  override).
- Bundled `LibZMQ`-shaped RBS (ADR-25).
- Option-catalogue → setter-method generation (ethon).
- High-level API refinements (`SecretBox#encrypt: (String, String) -> String`,
  `Easy#perform: () -> Integer`).

What's **deliberately out of scope** for the initial plugin:

- Use-after-free / double-free / leak diagnostics on FFI handles.
- Concrete struct-field bounds (the struct-array layouts in `FDSet` /
  `SHA256State` are fine for typing but not for bounds-checking).
- C-side compilation correctness (sassc-ruby's `ext/libsass` build).

### Negative-case takeaways from childprocess

- **Activate on FFI binding code**, not on "uses native resources".
- Don't false-positive on `::Process.spawn` / `::IO.pipe` /
  `::IO.popen` — those are core-Ruby and handled (or not) by stdlib
  RBS, not by `rigor-ffi`.

### Open questions for the design ADR

- DSL-recogniser shape: is `rigor-ffi` a single plugin with a
  pluggable recogniser table, or is `sodium_function` shipped by
  `rigor-rbnacl` consuming a `rigor-ffi`-provided contribution API?
  (Echoes the ADR-13 TypeNode-resolver chain debate.)
- Cross-gem signature acquisition: lean on ADR-25 (plugin-contributed
  RBS) for the ffi-rzmq-core case, or wait on ADR-10
  (dependency-source inference)? The two have different
  maintenance-cost / precision trade-offs.
- Should typedef'd opaque pointers default to nominal subtyping, or
  is it opt-in per `typedef` call (e.g. `typedef :pointer,
  :sass_data_context_ptr, nominal: true`)? Pure "always nominal"
  risks breaking gems that use typedef purely for documentation.
- How aggressively should the plugin model `FFI::Function.new` with a
  block? Anonymous-Proc inference is engine-wide work, not
  FFI-specific.

---

## Addendum — tenderlove's ffx ecosystem (2026-05-25, same-day)

Follow-on survey covering Aaron Patterson's recent FFI-replacement work,
added to clarify whether `rigor-ffi` needs a separate code path for
projects that target ffx instead of (or in addition to) the classic
`ffi` gem.

Sources read:

- Blog: [Tiny JITs for a Faster FFI](https://railsatscale.com/2025-02-12-tiny-jits-for-a-faster-ffi/) (2025-02-12)
- Conference: [RubyKaigi 2026 — "A Faster FFI"](https://rubykaigi.org/2026/presentations/tenderlove.html) (Patterson, 2026)
- Commentary (JP): [note.com/hatai_hatai](https://note.com/hatai_hatai/n/nd8f3749c59e7) — RubyKaigi 2026 recap
- Repos: [tenderlove/ffx](https://github.com/tenderlove/ffx), [tenderlove/sqliteffx](https://github.com/tenderlove/sqliteffx),
  [tenderlove/fisk](https://github.com/tenderlove/fisk), [tenderlove/aarch64](https://github.com/tenderlove/aarch64)

### The architectural sketch

ffx is **not** a runtime JIT in the way the blog title suggests after a
year of evolution. The shape that's actually shipping in `ffx@HEAD` and
demonstrated by `sqliteffx` is:

1. **Build time** — `FFX.create_makefile(name, src.rb, headers: [...])`
   in `extconf.rb` loads `src.rb`, introspects every `attach_function`
   declaration recorded against `FFI::Library`, and **emits a real C
   extension** to `$srcdir`. mkmf then builds it into a `.so` / `.bundle`.

2. **Runtime** — what's loaded is the compiled native extension, not
   FFI marshalling. Every `attach_function`-bound method is a real
   C function exposed via `rb_define_singleton_method`.

3. **JIT hint** — each generated C function ships in two parts:
   an `_impl` function (the marshalling body) and a **naked trampoline**
   with inline `__asm__` containing a `jmp _…_impl` followed by a binary
   metadata blob `[FFI0 magic | param_count | type_bytes | return_byte |
   asciz function_name]`. ZJIT reads the blob at offset 4 and emits
   specialised direct-call code.

The blog's "tiny JITs" framing maps onto the **fisk** / **aarch64**
codegen libraries that were part of the prototype path; the current
shipping shape uses inline `__asm__` in the generated C and lets
mkmf / the C compiler do the assembly. fisk / aarch64 remain useful
as standalone JIT libraries but are **not on ffx's runtime path**.

### Reported performance (for context, not load-bearing for rigor)

| Carrier (strlen wrapper) | ops/sec |
| --- | ---: |
| Pure ffi gem | ~15 M |
| Hand-written C extension | ~45 M |
| **ffx + ZJIT** | ~54 M |

(Numbers from the JP recap; consistent with the blog's earlier ~32.5 M
for FJIT vs ~29.8 M C-extension on a different bench.) The
practical claim — "Ruby-written FFI faster than a C extension" — has
held up far enough to land the RubyKaigi 2026 keynote slot.

### ffx surface analysis (against the same ten questions)

**The user-facing DSL is bit-identical to classic FFI.** ffx ships a
`module FFX::Library` and aliases it to `FFI::Library` so existing
binding files compile unchanged (`ffx.rb:244-246`). `extend FFI::Library`,
`ffi_lib "sqlite3"`, `attach_function :name, [args], ret` — all the
same syntactic forms.

What's different from the FFI gem at the surface level:

| Construct | classic ffi | ffx |
| --- | --- | --- |
| `attach_function` (primitives) | ✓ | ✓ |
| `ffi_lib` | ✓ | ✓ |
| `typedef` | ✓ | **✗ unsupported** |
| `callback` | ✓ | **✗ unsupported** (sqliteffx README:46-47 confirms) |
| `enum` / `bitmask` | ✓ | **✗ unsupported** |
| `FFI::Struct` / `Union` / `ManagedStruct` | ✓ | **✗ unsupported** |
| Variadic (`:varargs`) | ✓ | **✗ unsupported** |
| Custom type converters | ✓ | **✗ unsupported** |
| Primitive type symbols | dozens | 25 — `void, int, long, string, uint, size_t, double, float, pointer, bool, char, uchar, short, ushort, int{8,16,32,64}, uint{8,16,32,64}, long_long, ulong_long, ulong` (`ffx.rb:12-38`) |

**ffx is a strict subset of FFI.** This is the single most important
finding for `rigor-ffi`: a plugin that handles classic FFI handles
ffx-targetted code automatically, with *less* recogniser surface to
fire, not more.

### sqliteffx — the canonical ffx consumer

Centralised single-file binding declaration
(`ext/sqliteffx/sqliteffx.rb`, 44 lines). Two patterns matter for the
plugin design:

**(a) The `ffi.rb` stub redirection trick.**
sqliteffx ships an **empty `ext/sqliteffx/ffi.rb`** as a stub. When
`sqliteffx.rb` runs `require "ffi"` at extconf time on a Ruby load
path that has `ext/sqliteffx/` ahead of the installed ffi gem, the
stub wins and `extend FFI::Library` resolves to ffx's mixin.
At runtime nothing of the FFI gem is loaded — the compiled C extension
is.

For `rigor-ffi`, this means **a project file declaring
`extend FFI::Library` may be authored against either ffi or ffx**, and
the plugin cannot tell from the AST alone which target the gem build
process will use. The plugin must (a) cover the common subset
unconditionally, (b) only fire FFI-only-feature recognisers (callback,
struct, enum, typedef) when the project actually depends on the `ffi`
gem.

**(b) Opaque pointers as raw Ruby `Integer`.**
sqliteffx does **not** wrap SQLite handles in `FFI::Pointer`. It
allocates an 8-byte slot via `malloc`, calls `sqlite3_open` with the
slot as the out-parameter, then reads the slot back via
`Fiddle::Pointer.new(@slot)[0, 8].unpack1("Q<")` — landing a plain
Ruby `Integer` (`lib/sqliteffx.rb:41`). The Integer is then passed back
to `Sqliteffx.sqlite3_close(@handle)` as the `:pointer` argument.

ffx's marshalling for `:pointer` is `(void *)NUM2ULL(value)` — it
accepts any Ruby `Integer`. Classic FFI accepts `FFI::Pointer` and
auto-converts certain types but does **not** accept a bare `Integer`.

This is a real precision question for `rigor-ffi`: the `:pointer`
parameter type's accepted-input set is wider under ffx than under
classic FFI. The robustness-principle answer is to widen *inputs* to
`FFI::Pointer | Integer | nil` for `:pointer` parameters universally,
and let the ffi-gem-runtime errors at unsupported types be diagnosed
by the gem itself rather than by `rigor-ffi`. Returns stay strict —
classic FFI returns `FFI::Pointer`, ffx returns `Integer`; the
plugin keys off the project's target.

### fisk / aarch64 / JITBuffer — out of scope verdict

Both gems are **pure-Ruby instruction-encoder DSLs** with no FFI
binding surface of their own (no `attach_function`, no
`extend FFI::Library`, no FFI dependency — they use stdlib `Fiddle`
for `mmap` of executable pages). End-user code consuming ffx never
references `Fisk::*` or `AArch64::*` symbols. Even ffx itself doesn't
depend on them — the inline-`__asm__` trampoline avoids the codegen
gems entirely.

**Recommendation: `rigor-ffi` ignores fisk and aarch64.** They are
codegen backends used by people *writing* JITs, not by people writing
FFI bindings. A future `rigor-jit` plugin (if one is ever wanted)
might pick them up; that's a different surface area.

### Updates to the aggregated `rigor-ffi` shape

The plan in the main note's closing section stands, with three
adjustments:

**(1) The core plugin already handles ffx.** Because ffx accepts only
the FFI subset that's already in the "core plugin" bullet list
(literal `attach_function`, `ffi_lib`, primitive type symbols), no
ffx-specific recogniser is required. This is materially good news —
it means the first concrete consumer of `rigor-ffi` could be
sqliteffx with zero ffx-specific work.

**(2) New diagnostic family opportunity — `ffx.unsupported-feature`.**
If a project's gemspec resolves the `ffx` gem (or uses
`FFX.create_makefile` in `extconf.rb`), the plugin can statically
detect and diagnose ffx-incompatible declarations:

- `callback :foo, [...], :int` → `ffx.unsupported-callback`
- `class S < FFI::Struct` → `ffx.unsupported-struct`
- `typedef :pointer, :handle` → `ffx.unsupported-typedef`
- `enum :state, [:open, :closed]` → `ffx.unsupported-enum`
- `attach_function :printf, [:string, :varargs], :int` → `ffx.unsupported-varargs`
- Any type symbol outside the ffx-25 list → `ffx.unsupported-type`

These are precisely the cases ffx will fail to compile, so the
diagnostic surfaces a real, today bug — not a stylistic preference.
This is also a strong candidate for opt-in via the project's
configuration (a `target: ffx` axis on the rigor-ffi config) rather
than auto-detection, since "we use the ffx gem" is presence-based and
the plugin shouldn't surface noise on dual-target gems.

**(3) Pointer parameter input set widens.** The recommended type for a
`:pointer` parameter is `FFI::Pointer | Integer | nil` (robustness:
lenient inputs). The return type for a `:pointer`-returning function
stays strict and target-dependent: `FFI::Pointer` for the ffi-gem
target, `Integer` for the ffx target.

**(4) Long-term, optional — parsing the `FFI0` trampoline metadata as
a secondary signature source.** When the plugin encounters a gem
whose Ruby binding file is hidden (vendor blob, custom wrapper) but
whose installed `.so` exists, parsing the `FFI0` magic + type-byte
blob recovers `(name, arity, param_types, return_type)` from the
binary. This is the strongest form the trampoline metadata's
"static-analysis friendliness" can take. It's out of scope for the
initial plugin (requires platform-aware ELF / Mach-O / PE parsing)
but worth recording as a future direction — it's the closest thing
the FFI ecosystem has to a binary type-stub.

### Updated open questions

In addition to the four questions in the main note's closing section:

- **Target detection** — should `rigor-ffi` auto-detect the ffx
  target from `Gemfile.lock` / `gemspec` runtime dependencies,
  require explicit configuration, or both? Auto-detect is friendlier
  but couples the plugin to bundler / gemspec parsing.
- **Dual-target gems** — does any real-world gem ship both ffi-gem
  and ffx code paths conditionally? If yes, `ffx.unsupported-feature`
  diagnostics need a per-block suppression mechanism (the existing
  `# rigor:disable` should suffice).
- **Boundary with `rigor-fiddle`** — `Fiddle` is a separate stdlib
  FFI mechanism (used by sqliteffx for the out-parameter slot read).
  Should it be in scope for `rigor-ffi` or a sibling
  `rigor-fiddle` plugin? Probably sibling — different DSL surface,
  different binding registration shape.
