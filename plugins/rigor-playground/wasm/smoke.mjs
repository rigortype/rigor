// Headless runtime smoke test for the playground wasm (ADR-29 WD6 ③).
//
// Replicates the BROWSER DefaultRubyVM setup exactly — browser_wasi_shim with a
// writable in-memory "/" preopen — so it proves the production browser path
// headlessly: the VM boots, boot.rb stages a writable /work under the root, the
// js bridge carries the request, and the analysis must produce the same
// diagnostics the Rack backend does (WD2 contract fidelity in wasm).
//
// Run after `rake build`:  node smoke.mjs   (or: rake smoke)
import { File, OpenFile, PreopenDirectory, WASI } from "@bjorn3/browser_wasi_shim"
import { RubyVM } from "@ruby/wasm-wasi"
import fs from "node:fs"

const binary = fs.readFileSync(new URL("./rigor-playground.wasm", import.meta.url))
const module = await WebAssembly.compile(binary)

const fds = [
  new OpenFile(new File([])),
  new OpenFile(new File([])),
  new OpenFile(new File([])),
  new PreopenDirectory("/", new Map()),   // writable in-memory root, as the browser VM provides
]
const wasi = new WASI([], [], fds, { debug: false })
const { vm } = await RubyVM.instantiateModule({ module, wasip1: wasi })
vm.eval(`require "/bundle/setup"; require "/playground/boot"`)

function dispatch(kind, request) {
  globalThis.rigorRequestJson = JSON.stringify(request)
  return JSON.parse(vm.eval(`Rigor::Playground::Wasm.dispatch(${JSON.stringify(kind)})`).toString())
}

const SRC = `x = nil
x.upcase

class AscDesc
  # @rbs asc_or_desc: :asc | :desc
  def ascdesc(asc_or_desc)
    asc_or_desc
  end
end
AscDesc.new.ascdesc(:bad)
`

const r = dispatch("check", { source: SRC })
console.log(`success=${r.success} error_count=${r.error_count}`)
for (const d of r.diagnostics) console.log(`  L${d.line}:${d.column} [${d.rule}] ${d.message}`)

// Expect exactly the two diagnostics the backend produces for this snippet.
const rules = r.diagnostics.map((d) => d.rule).sort()
const ok = r.error_count === 2 &&
  rules.join(",") === "call.argument-type-mismatch,call.undefined-method"
console.log(ok ? "SMOKE OK" : "SMOKE FAILED")
process.exit(ok ? 0 : 1)
