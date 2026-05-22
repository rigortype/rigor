// Build script for the Rigor VSCode extension.
//
//   node esbuild.js              one-shot development build
//   node esbuild.js --watch      rebuild on change
//   node esbuild.js --production minified, no source map
//
// `vscode` is provided by the editor host at runtime and must stay
// external; everything else is bundled into a single CJS file.

const esbuild = require("esbuild");

const watch = process.argv.includes("--watch");
const production = process.argv.includes("--production");

async function main() {
  const ctx = await esbuild.context({
    entryPoints: ["src/extension.ts"],
    bundle: true,
    format: "cjs",
    platform: "node",
    target: "node18",
    outfile: "dist/extension.js",
    external: ["vscode"],
    sourcemap: !production,
    minify: production,
    logLevel: "info",
  });

  if (watch) {
    await ctx.watch();
  } else {
    await ctx.rebuild();
    await ctx.dispose();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
