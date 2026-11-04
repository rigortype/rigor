// Unit-test runner for the extension (`npm test`).
//
//   node test/build.js              bundle every test/*.test.ts and run them
//   node test/build.js tests.test   only the matching files
//
// Each test is bundled for node with `vscode` aliased to `test/vscode-stub.ts`
// (there is no editor host here), into `out/test/` (git- and vsix-ignored),
// then run with Node's built-in runner. Nothing beyond esbuild is needed.

const esbuild = require("esbuild");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const root = path.resolve(__dirname, "..");
const outdir = path.join(root, "out", "test");
const filter = process.argv.slice(2);

const entries = fs
  .readdirSync(__dirname)
  .filter((f) => f.endsWith(".test.ts"))
  .filter((f) => filter.length === 0 || filter.some((x) => f.includes(x)))
  .map((f) => path.join(__dirname, f));

if (entries.length === 0) {
  console.error("no test files match");
  process.exit(1);
}

fs.rmSync(outdir, { recursive: true, force: true });

esbuild
  .build({
    entryPoints: entries,
    bundle: true,
    format: "cjs",
    platform: "node",
    target: "node18",
    outdir,
    alias: {
      vscode: path.join(__dirname, "vscode-stub.ts"),
      "vscode-languageclient/node": path.join(__dirname, "languageclient-stub.ts"),
    },
    logLevel: "warning",
  })
  .then(() => {
    const files = fs
      .readdirSync(outdir)
      .filter((f) => f.endsWith(".js"))
      .map((f) => path.join(outdir, f));
    const result = spawnSync(process.execPath, ["--test", ...files], {
      stdio: "inherit",
    });
    process.exit(result.status ?? 1);
  })
  .catch(() => process.exit(1));
