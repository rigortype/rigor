// The managed runtime's decision logic: which Ruby installs it, how a build
// failure reads, when the timers refresh, what a background update check
// does, which versions are selected and which are pruned.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import {
  checkForUpdate,
  classifyBuildFailure,
  dedupeCandidates,
  findRuby,
  initRuntime,
  managedServer,
  miseLogActive,
  prune,
  refreshDue,
  rubyQualifies,
  updateDecision,
} from "../src/runtime";
import { ExtensionMode, stub } from "./vscode-stub";
import { Sandbox, fakeContext, fakeOutput, sandbox, script, write } from "./helpers";

let sb: Sandbox;

beforeEach(() => {
  stub.reset();
  sb = sandbox();
});

afterEach(() => {
  delete process.env.RIGOR_VSCODE_RUNTIME_GEM_PATH;
  sb.dispose();
});

describe("classifyBuildFailure", () => {
  it("a stdlib that does not load is a broken Ruby", () => {
    assert.equal(classifyBuildFailure("cannot load such file -- openssl (LoadError)"), "ruby");
    assert.equal(classifyBuildFailure("cannot load such file -- zlib"), "ruby");
    assert.equal(classifyBuildFailure("cannot load such file -- io/console"), "ruby");
    assert.equal(classifyBuildFailure("dlopen: incompatible library version (required 3)"), "ruby");
    assert.equal(classifyBuildFailure("LoadError: libssl.so.3: cannot open shared object file"), "ruby");
    assert.equal(classifyBuildFailure("x.rb:1: LoadError (libyaml not found)"), "ruby");
  });

  it("a certificate failure is tls", () => {
    assert.equal(classifyBuildFailure("certificate verify failed (unable to get local issuer certificate)"), "tls");
    assert.equal(classifyBuildFailure("SSL_connect returned=1 errno=0"), "tls");
    assert.equal(classifyBuildFailure("OpenSSL::SSL::SSLError: hostname mismatch"), "tls");
  });

  it("a native extension that did not build is compiler", () => {
    assert.equal(classifyBuildFailure("Gem::Ext::BuildError: ERROR: Failed to build gem native extension."), "compiler");
    assert.equal(classifyBuildFailure("Failed to build gem native extension"), "compiler");
  });

  it("the network and the gem are no classification", () => {
    assert.equal(classifyBuildFailure("Could not fetch specs from https://rubygems.org/"), undefined);
    assert.equal(classifyBuildFailure("Could not find gem 'rigortype (= 9.9.9)'"), undefined);
    assert.equal(classifyBuildFailure(""), undefined);
  });

  it("does not misfire on look-alikes", () => {
    // A TLS error that names OpenSSL is tls, not a Ruby that cannot load it.
    assert.equal(
      classifyBuildFailure("OpenSSL::SSL::SSLError: SSL_connect returned=1 (certificate verify failed)"),
      "tls",
    );
    // A compile error that mentions openssl headers is the compiler's.
    assert.equal(
      classifyBuildFailure("Failed to build gem native extension.\nopenssl/ssl.h not found"),
      "compiler",
    );
    // A different library whose name starts like a stdlib one.
    assert.equal(classifyBuildFailure("cannot load such file -- openssl_extras"), undefined);
    assert.equal(classifyBuildFailure("cannot load such file -- zlibrary"), undefined);
    assert.equal(classifyBuildFailure("cannot load such file -- bundler/setup"), undefined);
    // `LoadError` on one line, a stdlib name on another.
    assert.equal(classifyBuildFailure("LoadError: something\nchecking for openssl... yes"), undefined);
    // The word without the failure.
    assert.equal(classifyBuildFailure("Fetching openssl 3.2.0\nInstalling zlib 3.1.0"), undefined);
  });

  it("a broken Ruby wins over the later causes in the same log", () => {
    assert.equal(
      classifyBuildFailure("cannot load such file -- openssl\ncertificate verify failed\nFailed to build gem native extension"),
      "ruby",
    );
  });
});

describe("rubyQualifies", () => {
  const probe = (over: Partial<{ openssl: boolean; prerelease: boolean }>) => ({
    ruby: "/r/ruby",
    bundler: "/r/bundle",
    version: "4.0.1",
    openssl: true,
    prerelease: false,
    ...over,
  });

  it("needs OpenSSL, whoever named it", () => {
    assert.equal(rubyQualifies(probe({}), false), true);
    assert.equal(rubyQualifies(probe({ openssl: false }), false), false);
    assert.equal(rubyQualifies(probe({ openssl: false }), true), false);
  });

  it("a prerelease qualifies only when named", () => {
    assert.equal(rubyQualifies(probe({ prerelease: true }), false), false);
    assert.equal(rubyQualifies(probe({ prerelease: true }), true), true);
  });
});

describe("dedupeCandidates", () => {
  it("keeps the first of the candidates that resolve alike", () => {
    const real: Record<string, string> = { ruby: "/m/4.0.1/ruby", "/m/4.0.1/ruby": "/m/4.0.1/ruby", "/m/4.0.0/ruby": "/m/4.0.0/ruby" };
    assert.deepEqual(
      dedupeCandidates(["ruby", "/m/4.0.1/ruby", "/m/4.0.0/ruby"], (c) => real[c]),
      ["ruby", "/m/4.0.0/ruby"],
    );
  });
});

describe("findRuby", () => {
  const log = () => path.join(sb.dir, "probes.log");

  /** A Ruby that answers the probe (`-e`) the way `RUBY_PROBE` prints it. */
  function ruby(
    file: string,
    over: Partial<{ version: string; satisfied: boolean; prerelease: boolean; ssl: boolean; bundler: boolean }> = {},
  ): string {
    const o = { version: "4.0.1", satisfied: true, prerelease: false, ssl: true, bundler: true, ...over };
    return script(
      file,
      `echo "$0" >> "${log()}"\nprintf '${o.version}\\n${o.satisfied}\\n${file}\\n${o.bundler ? `${file}.bundle` : ""}\\n${o.prerelease}\\n${o.ssl}'`,
    );
  }
  const mise = (v: string) => path.join(process.env.MISE_DATA_DIR!, "installs", "ruby", v, "bin", "ruby");

  beforeEach(() => stub.set("rigor.runtime.rubyPath", ""));

  it("prefers ruby on PATH to the version managers' directories", async () => {
    ruby(path.join(sb.bin, "ruby"));
    ruby(mise("4.0.2"));
    const found = await findRuby(fakeOutput() as never);
    assert.equal(found?.ruby, path.join(sb.bin, "ruby"));
    assert.equal(found?.explicit, undefined);
  });

  it("takes the first qualifying Ruby in order, newest version directory first", async () => {
    ruby(mise("4.0.1"));
    ruby(mise("4.0.10"));
    ruby(mise("4.0.9"));
    ruby(path.join(sb.home, ".rbenv", "versions", "4.0.5", "bin", "ruby"));
    const found = await findRuby(fakeOutput() as never);
    assert.equal(found?.ruby, mise("4.0.10"));
  });

  it("walks mise, rbenv, rubies, then asdf", async () => {
    const asdf = path.join(process.env.ASDF_DATA_DIR!, "installs", "ruby", "4.0.1", "bin", "ruby");
    const rubies = path.join(sb.home, ".rubies", "ruby-4.0.1", "bin", "ruby");
    const rbenv = path.join(sb.home, ".rbenv", "versions", "4.0.1", "bin", "ruby");
    ruby(asdf);
    assert.equal((await findRuby(fakeOutput() as never))?.ruby, asdf);
    ruby(rubies);
    assert.equal((await findRuby(fakeOutput() as never))?.ruby, rubies);
    ruby(rbenv);
    assert.equal((await findRuby(fakeOutput() as never))?.ruby, rbenv);
    ruby(mise("4.0.1"));
    assert.equal((await findRuby(fakeOutput() as never))?.ruby, mise("4.0.1"));
  });

  it("skips a Ruby without OpenSSL, without Bundler, or outside the range", async () => {
    ruby(path.join(sb.bin, "ruby"), { ssl: false });
    ruby(mise("4.0.3"), { bundler: false });
    ruby(mise("4.0.2"), { satisfied: false });
    ruby(mise("4.0.1"));
    const found = await findRuby(fakeOutput() as never);
    assert.equal(found?.ruby, mise("4.0.1"));
  });

  it("skips a prerelease, and says why", async () => {
    ruby(path.join(sb.bin, "ruby"), { version: "4.0.0.preview2", prerelease: true });
    ruby(mise("4.0.1"));
    const out = fakeOutput();
    const found = await findRuby(out as never);
    assert.equal(found?.ruby, mise("4.0.1"));
    assert.ok(out.lines.some((l) => /prerelease/.test(l) && /rigor\.runtime\.rubyPath/.test(l)));
  });

  it("accepts a prerelease named in rubyPath, and marks it explicit", async () => {
    const pre = ruby(path.join(sb.dir, "pre", "ruby"), { version: "4.0.0.preview2", prerelease: true });
    ruby(mise("4.0.1"));
    stub.set("rigor.runtime.rubyPath", pre);
    const found = await findRuby(fakeOutput() as never);
    assert.equal(found?.ruby, pre);
    assert.equal(found?.explicit, true);
  });

  it("a rubyPath that does not qualify is warned about once, then others are searched", async () => {
    const bad = ruby(path.join(sb.dir, "bad", "ruby"), { ssl: false });
    ruby(mise("4.0.1"));
    stub.set("rigor.runtime.rubyPath", bad);
    const found = await findRuby(fakeOutput() as never);
    assert.equal(found?.ruby, mise("4.0.1"));
    assert.equal(stub.warnings().length, 1);
    assert.match(stub.warnings()[0], /rigor\.runtime\.rubyPath/);
  });

  it("probes one executable once however many names reach it", async () => {
    const target = ruby(mise("4.0.1"), { ssl: false });
    fs.symlinkSync(target, path.join(sb.bin, "ruby"));
    assert.equal(await findRuby(fakeOutput() as never), undefined);
    const probes = fs.readFileSync(log(), "utf8").trim().split("\n");
    assert.equal(probes.length, 1, probes.join("\n"));
  });

  it("skips the Rubies already tried", async () => {
    ruby(mise("4.0.2"));
    ruby(mise("4.0.1"));
    const found = await findRuby(fakeOutput() as never, new Set([fs.realpathSync(mise("4.0.2"))]));
    assert.equal(found?.ruby, mise("4.0.1"));
  });

  it("no qualifying Ruby is undefined, and the log lists what was looked at", async () => {
    ruby(mise("4.0.1"), { satisfied: false });
    const out = fakeOutput();
    assert.equal(await findRuby(out as never), undefined);
    assert.ok(out.lines.some((l) => /no Ruby >= 4\.0\.0, < 4\.1 with Bundler and OpenSSL among/.test(l)));
  });
});

describe("refreshDue", () => {
  const INTERVAL = 60_000;

  it("is not due on a punctual probe inside the interval", () => {
    assert.equal(refreshDue(10_000, 0, 0, INTERVAL), false);
  });

  it("is due once the wall clock says the interval is up", () => {
    assert.equal(refreshDue(60_000, 50_000, 0, INTERVAL), true);
    assert.equal(refreshDue(59_999, 49_999, 0, INTERVAL), false);
  });

  it("is due after a sleep: the probe came more than 15 s after the last one", () => {
    assert.equal(refreshDue(30_000, 15_000, 29_000, INTERVAL), false);
    assert.equal(refreshDue(30_001, 15_000, 29_000, INTERVAL), true);
  });

  it("is due when the clock was set back", () => {
    assert.equal(refreshDue(5_000, 9_000, 4_000, INTERVAL), true);
  });
});

describe("updateDecision", () => {
  const decide = (
    latest: string,
    installed: string[],
    running: string[],
    declined: string[] = [],
    answered: string[] = [],
  ) => updateDecision(latest, installed, running, new Set(declined), new Set(answered));

  it("does nothing when no managed server runs here", () => {
    assert.deepEqual(decide("0.5.0", ["0.4.7"], []), { kind: "none" });
  });

  it("does nothing when the running version is the latest or newer", () => {
    assert.deepEqual(decide("0.4.7", ["0.4.7"], ["0.4.7"]), { kind: "none" });
    assert.deepEqual(decide("0.4.7", ["0.4.8"], ["0.4.8"]), { kind: "none" });
  });

  it("compares versions numerically, and a dev install is newer than any release", () => {
    assert.deepEqual(decide("0.9.0", ["0.10.0"], ["0.10.0"]), { kind: "none" });
    assert.deepEqual(decide("0.10.0", ["0.9.0"], ["0.9.0"]), {
      kind: "install",
      version: "0.10.0",
      current: "0.9.0",
    });
    assert.deepEqual(decide("9.9.9", ["dev"], ["dev"]), { kind: "none" });
  });

  it("offers to install the latest when nothing installed is that new", () => {
    assert.deepEqual(decide("0.5.0", ["0.4.7"], ["0.4.7"]), { kind: "install", version: "0.5.0", current: "0.4.7" });
  });

  it("measures `current` by the newest running version", () => {
    assert.deepEqual(decide("0.5.0", ["0.4.7", "0.4.5"], ["0.4.5", "0.4.7"]), {
      kind: "install",
      version: "0.5.0",
      current: "0.4.7",
    });
  });

  it("a declined version is not offered again", () => {
    assert.deepEqual(decide("0.5.0", ["0.4.7"], ["0.4.7"], ["0.5.0"]), { kind: "none" });
    assert.deepEqual(decide("0.6.0", ["0.4.7"], ["0.4.7"], ["0.5.0"]), {
      kind: "install",
      version: "0.6.0",
      current: "0.4.7",
    });
  });

  it("offers a restart when another window installed the latest", () => {
    assert.deepEqual(decide("0.5.0", ["0.5.0", "0.4.7"], ["0.4.7"]), { kind: "restart", version: "0.5.0" });
  });

  it("a declined install does not suppress the restart offer", () => {
    assert.deepEqual(decide("0.5.0", ["0.5.0"], ["0.4.7"], ["0.5.0"]), { kind: "restart", version: "0.5.0" });
  });

  it("an answered restart is not offered again", () => {
    assert.deepEqual(decide("0.5.0", ["0.5.0"], ["0.4.7"], [], ["0.5.0"]), { kind: "none" });
  });

  it("offers the newest installed version, which may be past the latest", () => {
    assert.deepEqual(decide("0.5.0", ["0.5.1", "0.5.0"], ["0.4.7"]), { kind: "restart", version: "0.5.1" });
  });
});

describe("miseLogActive", () => {
  const QUIET = 15 * 60 * 1000;

  it("a log that grew lately and shows no ending is active", () => {
    assert.equal(miseLogActive("==> Downloading ruby-4.0.1.tar.gz\nmake[1]: Entering directory", 1000), true);
    assert.equal(miseLogActive("checking for strerror... yes", 0), true);
  });

  it("a log quiet for 15 minutes is not", () => {
    assert.equal(miseLogActive("compiling...", QUIET - 1), true);
    assert.equal(miseLogActive("compiling...", QUIET), false);
  });

  for (const [label, tail] of [
    ["ruby-build success", "Installed ruby-4.0.1 to /home/x/.local/share/mise/installs/ruby/4.0.1"],
    ["ruby-build failure", "BUILD FAILED (macOS 15 using ruby-build 20260101)"],
    ["a mise error", "mise ERROR failed to install ruby@4.0.1"],
    ["a lower-case mise error", "mise error: install failed"],
    ["mise's check mark", "mise ruby@4.0.1 ✓ installed"],
    ["mise's check mark followed by a warning", "mise ruby@4.0.1 ✓ installed\nmise WARN something\nmise hint: run mise use"],
  ] as const) {
    it(`${label} ends the install`, () => {
      assert.equal(miseLogActive(`compiling\n${tail}\n`, 1000), false);
    });
  }

  it("an earlier step's check mark does not end an install still running", () => {
    const earlier = "mise ruby@4.0.1 ✓ updated\n" + "cc -c a.c\n".repeat(6);
    assert.equal(miseLogActive(earlier, 1000), true);
  });

  it("a compiler Error: line, last or followed by more output, does not end the install", () => {
    assert.equal(miseLogActive("cc -c a.c\nError: unused variable x\n", 1000), true);
    assert.equal(miseLogActive("Error: unused variable x\nmake[2]: Leaving directory\n\n", 1000), true);
    assert.equal(miseLogActive("  ERROR: could not compile\n", 1000), true);
  });

  it("a final marker followed by a warning still ends the install", () => {
    assert.equal(miseLogActive("compiling\nInstalled ruby-4.0.1 to /x\nmise WARN stale cache\n", 1000), false);
  });

  it("a final marker more than five lines back is not the end", () => {
    assert.equal(miseLogActive("BUILD FAILED\n" + "retrying step\n".repeat(5), 1000), true);
  });

  it("the word error in the middle of a build line is not an ending", () => {
    assert.equal(miseLogActive("checking for error.h... yes\ncc -Werror -c x.c", 1000), true);
  });
});

describe("managed versions", () => {
  function install(storage: string, version: string): string {
    const dir = path.join(storage, "runtime", version);
    const ruby = script(path.join(sb.dir, "rubies", version, "ruby"), "true");
    const bundler = write(path.join(sb.dir, "rubies", version, "bundle"));
    write(path.join(dir, "rigor-runtime.json"), JSON.stringify({ version, rigortype: version, ruby, bundler }));
    return dir;
  }
  const storage = () => path.join(sb.dir, "storage");

  it("latest is the newest release by number, not by string", () => {
    for (const v of ["0.4.7", "0.4.10", "0.4.9"]) {
      install(storage(), v);
    }
    initRuntime(fakeContext(storage(), ExtensionMode.Production));
    assert.equal(managedServer()?.runtimeDir, path.join(storage(), "runtime", "0.4.10"));
  });

  it("rigor.runtime.version selects exactly that version", () => {
    for (const v of ["0.4.7", "0.4.10"]) {
      install(storage(), v);
    }
    initRuntime(fakeContext(storage(), ExtensionMode.Production));
    stub.set("rigor.runtime.version", " 0.4.7 ");
    assert.equal(managedServer()?.runtimeDir, path.join(storage(), "runtime", "0.4.7"));
    stub.set("rigor.runtime.version", "0.4.8");
    assert.equal(managedServer(), undefined);
  });

  it("a production window never selects dev, whether latest or asked for by name", () => {
    install(storage(), "dev");
    install(storage(), "0.4.7");
    initRuntime(fakeContext(storage(), ExtensionMode.Production));
    assert.equal(managedServer()?.runtimeDir, path.join(storage(), "runtime", "0.4.7"));
    stub.set("rigor.runtime.version", "dev");
    assert.equal(managedServer(), undefined);
  });

  it("a development window without the override does not select dev either", () => {
    install(storage(), "dev");
    install(storage(), "0.4.7");
    initRuntime(fakeContext(storage(), ExtensionMode.Development));
    assert.equal(managedServer()?.runtimeDir, path.join(storage(), "runtime", "0.4.7"));
  });

  it("the development override selects dev", () => {
    install(storage(), "dev");
    install(storage(), "0.4.7");
    process.env.RIGOR_VSCODE_RUNTIME_GEM_PATH = "/some/checkout";
    initRuntime(fakeContext(storage(), ExtensionMode.Development));
    assert.equal(managedServer()?.runtimeDir, path.join(storage(), "runtime", "dev"));
  });

  it("the override is ignored in production", () => {
    install(storage(), "dev");
    install(storage(), "0.4.7");
    process.env.RIGOR_VSCODE_RUNTIME_GEM_PATH = "/some/checkout";
    initRuntime(fakeContext(storage(), ExtensionMode.Production));
    assert.equal(managedServer()?.runtimeDir, path.join(storage(), "runtime", "0.4.7"));
  });

  it("an install whose manifest names another version or lacks its Ruby is ignored", () => {
    const dir = install(storage(), "0.4.7");
    const wrong = install(storage(), "0.4.8");
    write(path.join(wrong, "rigor-runtime.json"), JSON.stringify({ version: "0.4.9", ruby: "/x", bundler: "/y" }));
    const missing = install(storage(), "0.4.6");
    fs.rmSync(JSON.parse(fs.readFileSync(path.join(missing, "rigor-runtime.json"), "utf8")).ruby);
    initRuntime(fakeContext(storage(), ExtensionMode.Production));
    assert.equal(managedServer()?.runtimeDir, dir);
  });

  it("runs the Ruby directly, without a shell, under a frozen bundle", () => {
    install(storage(), "0.4.7");
    initRuntime(fakeContext(storage(), ExtensionMode.Production));
    const server = managedServer()!;
    assert.equal(server.shell, false);
    assert.deepEqual(server.prefixArgs.slice(1), ["exec", "rigor"]);
    assert.equal(server.env?.BUNDLE_FROZEN, "true");
    assert.equal(server.env?.BUNDLE_GEMFILE, path.join(storage(), "runtime", "0.4.7", "Gemfile"));
  });
});

describe("prune", () => {
  const storage = () => path.join(sb.dir, "storage");
  const root = () => path.join(storage(), "runtime");

  function install(version: string): string {
    const dir = path.join(root(), version);
    const ruby = script(path.join(sb.dir, "rubies", version, "ruby"), "true");
    const bundler = write(path.join(sb.dir, "rubies", version, "bundle"));
    write(path.join(dir, "rigor-runtime.json"), JSON.stringify({ version, rigortype: version, ruby, bundler }));
    return dir;
  }
  const remaining = () =>
    fs
      .readdirSync(root())
      .filter((n) => !n.startsWith("."))
      .sort();

  beforeEach(() => initRuntime(fakeContext(storage(), ExtensionMode.Production)));

  it("keeps the newest two: the one just installed and one more", () => {
    for (const v of ["0.4.6", "0.4.7", "0.4.8", "0.4.9"]) {
      install(v);
    }
    prune("0.4.9");
    assert.deepEqual(remaining(), ["0.4.8", "0.4.9"]);
  });

  it("counts the kept version among the two, wherever it ranks", () => {
    for (const v of ["0.4.6", "0.4.7", "0.4.8", "0.4.9"]) {
      install(v);
    }
    prune("0.4.6");
    assert.deepEqual(remaining(), ["0.4.6", "0.4.9"]);
  });

  it("removes nothing when two or fewer are installed", () => {
    install("0.4.8");
    install("0.4.9");
    prune("0.4.9");
    assert.deepEqual(remaining(), ["0.4.8", "0.4.9"]);
  });

  it("a version a live window marks in use is kept", () => {
    for (const v of ["0.4.7", "0.4.8", "0.4.9"]) {
      install(v);
    }
    write(path.join(root(), "0.4.7", ".in-use", String(process.pid)));
    prune("0.4.9");
    assert.deepEqual(remaining(), ["0.4.7", "0.4.8", "0.4.9"]);
  });

  it("a marker of a dead process, or one untouched for a day, protects nothing", () => {
    for (const v of ["0.4.5", "0.4.6", "0.4.8", "0.4.9"]) {
      install(v);
    }
    const dead = spawnSync(process.execPath, ["-e", ""]).pid!;
    write(path.join(root(), "0.4.5", ".in-use", String(dead)));
    const old = write(path.join(root(), "0.4.6", ".in-use", String(process.pid)));
    const twoDaysAgo = new Date(Date.now() - 2 * 24 * 60 * 60 * 1000);
    fs.utimesSync(old, twoDaysAgo, twoDaysAgo);
    prune("0.4.9");
    assert.deepEqual(remaining(), ["0.4.8", "0.4.9"]);
  });

  it("does not count or remove dev in a production window", () => {
    for (const v of ["dev", "0.4.7", "0.4.8", "0.4.9"]) {
      install(v);
    }
    prune("0.4.9");
    assert.deepEqual(remaining(), ["0.4.8", "0.4.9", "dev"]);
  });

  it("removes the leftovers of installs that died, and leaves what is not its to judge", () => {
    install("0.4.9");
    write(path.join(root(), ".tmp-abc", "x"));
    write(path.join(root(), ".old-abc", "x"));
    write(path.join(root(), ".lock"), "token");
    write(path.join(root(), "stray", "file"));
    prune("0.4.9");
    assert.deepEqual(fs.readdirSync(root()).sort(), [".lock", "0.4.9", "stray"]);
  });
});

describe("checkForUpdate with rigor.runtime.version dev", () => {
  afterEach(() => {
    // `devGemPath` is module state: leave it as a production window has it.
    delete process.env.RIGOR_VSCODE_RUNTIME_GEM_PATH;
    initRuntime(fakeContext(path.join(sb.dir, "storage"), ExtensionMode.Production));
  });

  const info = (): string[] => stub.messages.filter((m) => m.level === "info").map((m) => m.text);

  it("a production window says dev is only valid in an extension development host", async () => {
    initRuntime(fakeContext(path.join(sb.dir, "storage"), ExtensionMode.Production));
    stub.set("rigor.runtime.version", "dev");
    await checkForUpdate(fakeOutput() as never);
    assert.equal(info().length, 1);
    assert.match(info()[0], /only valid in an extension development host/);
    assert.doesNotMatch(info()[0], /development install from a local checkout/);
  });

  it("a development host with the override keeps the development-install message", async () => {
    process.env.RIGOR_VSCODE_RUNTIME_GEM_PATH = sb.dir;
    initRuntime(fakeContext(path.join(sb.dir, "storage"), ExtensionMode.Development));
    stub.set("rigor.runtime.version", "dev");
    await checkForUpdate(fakeOutput() as never);
    assert.match(info()[0], /development install from a local checkout/);
  });
});
