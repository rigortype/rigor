// The discovery walk (`resolveRigor`) and its decision table: which `rigor`
// serves a folder, in what order, and what is final. Candidates are fake
// executables (shell scripts) in a sandbox, so the real probe, PATH and
// filesystem code run.

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { pathExecutables, versionManagerShims } from "../src/discovery";
import { forgetResolutions, lockMatches, pinChanged, resolveRigor } from "../src/resolve";
import { initRuntime } from "../src/runtime";
import { addFolder, ExtensionMode, stub } from "./vscode-stub";
import {
  Sandbox,
  fakeContext,
  fakeOutput,
  fakeRigor,
  lockfile,
  sandbox,
  script,
  withPlatform,
  write,
} from "./helpers";

let sb: Sandbox;

beforeEach(() => {
  stub.reset();
  sb = sandbox();
});

afterEach(() => {
  forgetResolutions();
  sb.dispose();
});

const walk = () => resolveRigor(addFolder(sb.project), fakeOutput() as never);

/** Fake `bundle`: prints the version only when run as `exec rigor version`. */
function fakeBundle(version: string): string {
  return script(
    path.join(sb.bin, "bundle"),
    `[ "$1 $2 $3" = "exec rigor version" ] || exit 2\necho "rigor ${version}"`,
  );
}

describe("lockMatches", () => {
  it("accepts the same version and a platform suffix", () => {
    assert.equal(lockMatches("0.4.7", "0.4.7"), true);
    assert.equal(lockMatches("0.4.7-x86_64-linux", "0.4.7"), true);
  });

  it("rejects a version that only starts the same", () => {
    assert.equal(lockMatches("0.4.1", "0.4.10"), false);
    assert.equal(lockMatches("0.4.10", "0.4.1"), false);
  });

  it("rejects a prerelease of the locked version, either way round", () => {
    assert.equal(lockMatches("0.5.0", "0.5.0.pre1"), false);
    assert.equal(lockMatches("0.5.0.pre1", "0.5.0"), false);
  });

  it("treats no printed version as a mismatch", () => {
    assert.equal(lockMatches("0.4.7", undefined), false);
  });
});

describe("explicit rigor.server.path", () => {
  it("is final: a failing explicit path is reported, never replaced", async () => {
    fakeRigor(path.join(sb.bin, "rigor"), "9.9.9");
    stub.set("rigor.server.path", path.join(sb.dir, "missing", "rigor"));
    const res = await walk();
    assert.equal(res.server.kind, "explicit");
    assert.equal(res.probe.ok, false);
    assert.equal(res.probe.notFound, true);
    assert.equal(res.managedReachable, false);
  });

  it("strips one pair of surrounding quotes (the pre-#2743 Windows workaround)", async () => {
    const explicit = fakeRigor(path.join(sb.dir, "own dir", "rigor"), "0.4.7");
    stub.set("rigor.server.path", `"${explicit}"`);
    const res = await walk();
    assert.equal(res.server.command, explicit);
    assert.equal(res.probe.ok, true);
  });

  it("wins over a project lockfile pin", async () => {
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    fakeBundle("0.4.7");
    const explicit = fakeRigor(path.join(sb.dir, "own", "rigor"), "0.4.7");
    stub.set("rigor.server.path", explicit);
    const res = await walk();
    assert.equal(res.server.kind, "explicit");
    assert.equal(res.server.command, explicit);
    assert.equal(res.probe.ok, true);
    assert.equal(res.pin, undefined);
  });
});

describe("project lockfile pin", () => {
  for (const name of ["Gemfile.lock", "gems.locked"]) {
    it(`${name} is served by bundle exec rigor and nothing else`, async () => {
      write(path.join(sb.project, name), lockfile("0.4.7"));
      fakeBundle("0.4.7");
      fakeRigor(path.join(sb.bin, "rigor"), "9.9.9");
      const res = await walk();
      assert.equal(res.server.kind, "bundler");
      assert.equal(res.probe.ok, true);
      assert.deepEqual(res.pin, { kind: "lock", file: path.join(sb.project, name) });
      assert.equal(res.managedReachable, false);
    });
  }

  it("is final: a bundle that runs another version is rejected, PATH is not tried", async () => {
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    fakeBundle("0.4.6");
    fakeRigor(path.join(sb.bin, "rigor"), "9.9.9");
    const res = await walk();
    assert.equal(res.server.kind, "bundler");
    assert.equal(res.probe.ok, false);
    assert.match(res.rejected[0].reason, /pins 0\.4\.7/);
    assert.equal(res.rejected.length, 1);
  });

  it("is final: no bundle executable is not a reason to use the PATH rigor", async () => {
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    fakeRigor(path.join(sb.bin, "rigor"), "9.9.9");
    const res = await walk();
    assert.equal(res.server.kind, "bundler");
    assert.equal(res.probe.notFound, true);
  });

  it("a bundle that falls through to an old rigor is rejected as a mismatch, not as too old", async () => {
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    fakeBundle("0.1.0");
    const res = await walk();
    assert.equal(res.probe.ok, false);
    assert.equal(res.probe.tooOld, false);
    assert.equal(res.rejected.length, 1);
    assert.match(res.rejected[0].reason, /runs rigortype 0\.1\.0, but .* pins 0\.4\.7/);
  });

  it("accepts a lockfile version with a platform suffix", async () => {
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7-arm64-darwin"));
    fakeBundle("0.4.7");
    const res = await walk();
    assert.equal(res.probe.ok, true);
  });

  it("a lockfile that does not pin rigortype is no pin", async () => {
    write(path.join(sb.project, "Gemfile.lock"), "GEM\n  specs:\n    rake (13.0.0)\n");
    fakeRigor(path.join(sb.bin, "rigor"), "0.4.7");
    const res = await walk();
    assert.equal(res.server.kind, "global");
    assert.equal(res.pin, undefined);
  });
});

describe("pinned bundle", () => {
  const pinnedLock = () => path.join(sb.project, ".github", "rigor", "Gemfile.lock");

  /** Prints the right version only when BUNDLE_GEMFILE names the pinned Gemfile. */
  function bundleChecking(gemfile: string): void {
    script(
      path.join(sb.bin, "bundle"),
      `if [ "$BUNDLE_GEMFILE" = "${gemfile}" ]; then echo "rigor 0.4.7"; else echo "rigor 0.0.9"; fi`,
    );
  }

  it(".github/rigor/Gemfile.lock serves under its own BUNDLE_GEMFILE", async () => {
    write(pinnedLock(), lockfile("0.4.7"));
    const gemfile = path.join(sb.project, ".github", "rigor", "Gemfile");
    bundleChecking(gemfile);
    fakeRigor(path.join(sb.bin, "rigor"), "9.9.9");
    const res = await walk();
    assert.equal(res.server.kind, "pinned-bundle");
    assert.equal(res.server.env?.BUNDLE_GEMFILE, gemfile);
    assert.equal(res.probe.ok, true);
    assert.equal(res.pin?.kind, "pinned-bundle");
  });

  it("the project lockfile wins over the pinned bundle", async () => {
    write(pinnedLock(), lockfile("0.4.7"));
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    fakeBundle("0.4.7");
    const res = await walk();
    assert.equal(res.server.kind, "bundler");
  });

  it("rigor.server.bundleGemfile selects another bundle inside the project", async () => {
    write(path.join(sb.project, "ci", "Gemfile.lock"), lockfile("0.4.7"));
    bundleChecking(path.join(sb.project, "ci", "Gemfile"));
    stub.set("rigor.server.bundleGemfile", "ci/Gemfile");
    const res = await walk();
    assert.equal(res.server.kind, "pinned-bundle");
    assert.equal(res.probe.ok, true);
  });

  for (const [label, value] of [
    ["leaves the project", "../elsewhere/Gemfile"],
    ["is absolute", "/etc/Gemfile"],
  ]) {
    it(`a bundleGemfile that ${label} is rejected: warned, no pinned bundle used`, async () => {
      write(path.join(sb.dir, "elsewhere", "Gemfile.lock"), lockfile("0.4.7"));
      fakeBundle("0.4.7");
      fakeRigor(path.join(sb.bin, "rigor"), "0.4.7");
      stub.set("rigor.server.bundleGemfile", value);
      const res = await walk();
      assert.equal(res.server.kind, "global");
      assert.equal(res.pin, undefined);
      assert.equal(stub.warnings().length, 1);
      assert.match(stub.warnings()[0], /not a path inside the project root/);
    });
  }

  it("runs under the Ruby the bundle's lockfile asks for, via that Ruby's bundler", async () => {
    write(pinnedLock(), `${lockfile("0.4.7")}RUBY VERSION\n   ruby 4.0.1\n`);
    write(path.join(sb.project, ".github", "rigor", "Gemfile"), "source 'https://rubygems.org'\n");
    const bundler = script(path.join(sb.dir, "r", "bundle"), "true");
    const ruby = path.join(sb.dir, "r", "ruby");
    // `-e` is the Ruby probe: version, RbConfig.ruby, bundler, prerelease?,
    // openssl, then one boolean per requirement (the lockfile's, rigortype's).
    script(
      ruby,
      `if [ "$1" = "-e" ]; then printf '4.0.1\\n${ruby}\\n${bundler}\\nfalse\\ntrue\\ntrue,true\\n'; else echo "rigor 0.4.7"; fi`,
    );
    stub.set("rigor.runtime.rubyPath", ruby);
    const res = await walk();
    assert.equal(res.server.kind, "pinned-bundle");
    assert.equal(res.server.command, ruby);
    assert.deepEqual(res.server.prefixArgs, [bundler, "exec", "rigor"]);
    assert.equal(res.probe.ok, true);
  });
});

describe("mise / asdf pins", () => {
  const shim = () => path.join(process.env.MISE_DATA_DIR!, "shims", "rigor");

  it("a project mise pin is served by the shim only; a PATH rigor under mise installs never serves it", async () => {
    write(path.join(sb.project, "mise.toml"), '[tools]\n"gem:rigortype" = "0.4.7"\n');
    fakeRigor(shim(), "0.4.7");
    // The installs directory is on PATH, as `mise activate` puts it.
    fakeRigor(path.join(process.env.MISE_DATA_DIR!, "installs", "gem-rigortype", "0.4.7", "bin", "rigor"), "9.9.9");
    process.env.PATH = `${path.join(process.env.MISE_DATA_DIR!, "installs", "gem-rigortype", "0.4.7", "bin")}:${process.env.PATH}`;
    const res = await walk();
    assert.equal(res.server.kind, "version-manager");
    assert.equal(res.server.command, shim());
    assert.equal(res.probe.version, "0.4.7");
    assert.equal(res.pin?.kind, "tool");
    assert.equal(res.managedReachable, false);
  });

  it("a failing shim ends the walk: the PATH rigor is not tried", async () => {
    write(path.join(sb.project, ".tool-versions"), "ruby 4.0.1\nrigortype 0.4.7\n");
    script(shim(), "echo broken >&2; exit 1");
    fakeRigor(path.join(sb.bin, "rigor"), "9.9.9");
    const res = await walk();
    assert.equal(res.server.kind, "version-manager");
    assert.equal(res.probe.ok, false);
    assert.equal(res.rejected.length, 1);
  });

  it("no shim at all is not-found, not a fall-through to PATH", async () => {
    write(path.join(sb.project, "mise.toml"), '[tools]\nrigortype = "0.4.7"\n');
    fakeRigor(path.join(sb.bin, "rigor"), "9.9.9");
    const res = await walk();
    assert.equal(res.server.kind, "version-manager");
    assert.equal(res.probe.notFound, true);
    assert.deepEqual(res.rejected, []);
  });

  it("a mise pin that names another tool is no pin", async () => {
    write(path.join(sb.project, "mise.toml"), '[tools]\nruby = "4.0"\n[env]\nrigortype = "x"\n');
    fakeRigor(path.join(sb.bin, "rigor"), "0.4.7");
    const res = await walk();
    assert.equal(res.server.kind, "global");
    assert.equal(res.pin, undefined);
  });

  it("a global pin with a rigortype installed is not final: PATH serves, managed does not", async () => {
    write(path.join(sb.home, ".tool-versions"), "rigortype 0.4.7\n");
    write(path.join(process.env.MISE_DATA_DIR!, "installs", "gem-rigortype", "0.4.7", "keep"));
    fakeRigor(path.join(sb.bin, "rigor"), "0.4.7");
    const res = await walk();
    assert.equal(res.server.kind, "global");
    assert.equal(res.pin, undefined);
    assert.equal(res.managedReachable, false);
  });
});

describe("rigor.server.useBundler", () => {
  it("never: ignores a lockfile pin (warned once per folder) and uses PATH", async () => {
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    fakeBundle("0.4.7");
    fakeRigor(path.join(sb.bin, "rigor"), "0.4.7");
    stub.set("rigor.server.useBundler", "never");
    const first = await walk();
    assert.equal(first.server.kind, "global");
    assert.equal(stub.warnings().length, 1);
    assert.match(stub.warnings()[0], /useBundler/);
    forgetResolutions();
    await walk();
    assert.equal(stub.warnings().length, 1, "warned again for the same folder");
  });

  it("never: a project mise pin is still final", async () => {
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    write(path.join(sb.project, "mise.toml"), '[tools]\nrigortype = "0.4.7"\n');
    fakeRigor(path.join(process.env.MISE_DATA_DIR!, "shims", "rigor"), "0.4.7");
    fakeRigor(path.join(sb.bin, "rigor"), "9.9.9");
    stub.set("rigor.server.useBundler", "never");
    const res = await walk();
    assert.equal(res.server.kind, "version-manager");
    assert.equal(res.pin?.kind, "tool");
  });

  it("never with an explicit path does not warn", async () => {
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    stub.set("rigor.server.useBundler", "never");
    stub.set("rigor.server.path", fakeRigor(path.join(sb.dir, "own", "rigor"), "0.4.7"));
    await walk();
    assert.deepEqual(stub.warnings(), []);
  });

  it("always: the only candidate is bundle exec rigor, even without a pin", async () => {
    fakeBundle("0.4.7");
    fakeRigor(path.join(sb.bin, "rigor"), "9.9.9");
    stub.set("rigor.server.useBundler", "always");
    const res = await walk();
    assert.equal(res.server.kind, "bundler");
    assert.equal(res.probe.ok, true);
    assert.match(res.hint ?? "", /no Gemfile\.lock or pinned bundle pins rigortype/);
    assert.equal(res.managedReachable, false);
  });

  it("always with a bundleGemfile uses the pinned bundle", async () => {
    write(path.join(sb.project, "ci", "Gemfile.lock"), lockfile("0.4.7"));
    script(path.join(sb.bin, "bundle"), 'echo "rigor 0.4.7"');
    stub.set("rigor.server.useBundler", "always");
    stub.set("rigor.server.bundleGemfile", "ci/Gemfile");
    const res = await walk();
    assert.equal(res.server.kind, "pinned-bundle");
    assert.equal(res.pin?.kind, "pinned-bundle");
  });
});

describe("walking PATH", () => {
  it("a candidate that is too old stops the walk", async () => {
    fakeRigor(path.join(sb.bin, "rigor"), "0.1.0");
    fakeRigor(path.join(sb.dir, "bin2", "rigor"), "0.4.7");
    process.env.PATH = `${sb.bin}:${path.join(sb.dir, "bin2")}:${sb.sysbin}`;
    const res = await walk();
    assert.equal(res.probe.tooOld, true);
    assert.equal(res.server.command, path.join(sb.bin, "rigor"));
    assert.deepEqual(res.rejected, []);
  });

  it("a candidate that does not run falls through to the next, and is recorded", async () => {
    script(path.join(sb.bin, "rigor"), "echo 'shim: no rigor for this ruby' >&2; exit 1");
    fakeRigor(path.join(sb.dir, "bin2", "rigor"), "0.4.7");
    process.env.PATH = `${sb.bin}:${path.join(sb.dir, "bin2")}:${sb.sysbin}`;
    const res = await walk();
    assert.equal(res.probe.ok, true);
    assert.equal(res.server.command, path.join(sb.dir, "bin2", "rigor"));
    assert.equal(res.rejected.length, 1);
    assert.equal(res.rejected[0].reason, "shim: no rigor for this ruby");
  });

  it("a PATH rigor that is also a shim is one candidate, rejected once", async () => {
    const shim = script(path.join(process.env.MISE_DATA_DIR!, "shims", "rigor"), "exit 1");
    process.env.PATH = `${path.dirname(shim)}:${sb.sysbin}`;
    const res = await walk();
    assert.equal(res.probe.ok, false);
    assert.equal(res.rejected.length, 1);
  });

  it("relative PATH entries are skipped and logged", async () => {
    fakeRigor(path.join(sb.project, "rel", "rigor"), "0.4.7");
    process.env.PATH = `rel:.:${sb.sysbin}`;
    const out = fakeOutput();
    const res = await resolveRigor(addFolder(sb.project), out as never);
    assert.equal(res.probe.notFound, true);
    assert.ok(out.lines.some((l) => /relative PATH entries not searched: rel, \./.test(l)), out.lines.join("\n"));
  });

  it("falls back to the managed Rigor only for a project with no pin", async () => {
    const storage = path.join(sb.dir, "storage");
    const dir = path.join(storage, "runtime", "0.4.7");
    const ruby = fakeRigor(path.join(sb.dir, "mruby", "ruby"), "0.4.7");
    const bundler = write(path.join(sb.dir, "mruby", "bundle"));
    write(
      path.join(dir, "rigor-runtime.json"),
      JSON.stringify({ version: "0.4.7", rigortype: "0.4.7", ruby, bundler }),
    );
    initRuntime(fakeContext(storage, ExtensionMode.Production));
    const free = await walk();
    assert.equal(free.server.kind, "managed");
    assert.equal(free.managedReachable, true);
    forgetResolutions();

    // The same install never serves a pinned project (a failing bundle here).
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    const pinned = await walk();
    assert.equal(pinned.server.kind, "bundler");
    assert.equal(pinned.managedReachable, false);
  });
});

describe("discovery budget", () => {
  it("skips non-final candidates after the budget, but still tries a pin's own", async () => {
    const realNow = Date.now;
    let offset = 0;
    Date.now = () => realNow() + offset;
    try {
      // Non-final: the first candidate fails; time then jumps past the budget.
      script(path.join(sb.bin, "rigor"), "exit 1");
      fakeRigor(path.join(sb.dir, "bin2", "rigor"), "0.4.7");
      process.env.PATH = `${sb.bin}:${path.join(sb.dir, "bin2")}:${sb.sysbin}`;
      const out = fakeOutput();
      const appendLine = out.appendLine;
      out.appendLine = (s: string) => {
        appendLine(s);
        if (s.includes("rejected")) {
          offset = 60_000;
        }
      };
      const res = await resolveRigor(addFolder(sb.project), out as never);
      assert.equal(res.probe.ok, false);
      assert.match(res.rejected[1].reason, /not tried: discovery ran past 45 s/);
      forgetResolutions();
      offset = 0;
      stub.reset();

      // Final (a pin's shims): both shims are tried however long it took.
      write(path.join(sb.project, "mise.toml"), '[tools]\nrigortype = "0.4.7"\n');
      script(path.join(process.env.MISE_DATA_DIR!, "shims", "rigor"), "exit 1");
      fakeRigor(path.join(process.env.ASDF_DATA_DIR!, "shims", "rigor"), "0.4.7");
      const out2 = fakeOutput();
      const append2 = out2.appendLine;
      out2.appendLine = (s: string) => {
        append2(s);
        if (s.includes("rejected")) {
          offset = 60_000;
        }
      };
      const res2 = await resolveRigor(addFolder(sb.project), out2 as never);
      assert.equal(res2.probe.ok, true);
      assert.equal(res2.server.command, path.join(process.env.ASDF_DATA_DIR!, "shims", "rigor"));
    } finally {
      Date.now = realNow;
    }
  });
});

describe("pinChanged", () => {
  it("sees a lockfile appear, and ignores an unrelated edit to a mise file", async () => {
    write(path.join(sb.project, "mise.toml"), '[tools]\nrigortype = "0.4.7"\n');
    const folder = addFolder(sb.project);
    await resolveRigor(folder, fakeOutput() as never);
    assert.equal(pinChanged(folder), false);
    write(path.join(sb.project, "mise.toml"), '[tools]\nrigortype = "0.4.7"\n[env]\nA = "1"\n');
    assert.equal(pinChanged(folder), false);
    write(path.join(sb.project, "mise.toml"), '[tools]\nrigortype = "0.5.0"\n');
    assert.equal(pinChanged(folder), true);
  });
});

describe("pathExecutables", () => {
  it("lists a symlinked directory's rigor once", () => {
    fakeRigor(path.join(sb.dir, "real", "rigor"), "0.4.7");
    fs.symlinkSync(path.join(sb.dir, "real"), path.join(sb.dir, "link"));
    process.env.PATH = `${path.join(sb.dir, "real")}:${path.join(sb.dir, "link")}`;
    const { found } = pathExecutables("rigor");
    assert.deepEqual(found, [path.join(sb.dir, "real", "rigor")]);
  });

  it("a directory named rigor is not an executable", () => {
    fs.mkdirSync(path.join(sb.bin, "rigor"));
    assert.deepEqual(pathExecutables("rigor").found, []);
  });

  it("on Windows lists .bat, .cmd and .exe in that order, never the extensionless script", async () => {
    for (const f of ["rigor", "rigor.exe", "rigor.cmd", "rigor.bat"]) {
      write(path.join(sb.bin, f));
    }
    process.env.PATH = `${sb.bin};/elsewhere`;
    await withPlatform("win32", () => {
      const { found } = pathExecutables("rigor");
      assert.deepEqual(
        found.map((f) => path.basename(f)),
        ["rigor.bat", "rigor.cmd", "rigor.exe"],
      );
    });
  });

  it("on Windows the shims are rigor.bat, .cmd and .exe, mise's first", async () => {
    const mise = path.join(process.env.MISE_DATA_DIR!, "shims");
    const asdf = path.join(process.env.ASDF_DATA_DIR!, "shims");
    for (const f of ["rigor.exe", "rigor.bat"]) {
      write(path.join(mise, f));
    }
    write(path.join(asdf, "rigor.cmd"));
    await withPlatform("win32", () => {
      assert.deepEqual(versionManagerShims(), [
        path.join(mise, "rigor.bat"),
        path.join(mise, "rigor.exe"),
        path.join(asdf, "rigor.cmd"),
      ]);
    });
  });
});
