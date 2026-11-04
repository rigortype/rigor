// The CLI-backed commands' decision logic: the baseline lookup table, the
// rule-list parser and the lightbulb's rule cache.

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { baselineLookup, clearRuleCache, parseRuleList, registerCommands } from "../src/commands";
import { forgetResolutions } from "../src/resolve";
import { ExtensionMode, Uri, addFolder, registeredCodeActionProviders, stub } from "./vscode-stub";
import { Sandbox, fakeContext, fakeOutput, sandbox, script, waitFor, write } from "./helpers";

let sb: Sandbox;

beforeEach(() => {
  stub.reset();
  sb = sandbox();
});

afterEach(() => {
  forgetResolutions();
  clearRuleCache();
  sb.dispose();
});

describe("baselineLookup", () => {
  const lookup = (config: string | undefined, file = ".rigor.yml") => {
    stub.reset();
    fs.rmSync(path.join(sb.project, ".rigor.yml"), { force: true });
    fs.rmSync(path.join(sb.project, ".rigor.dist.yml"), { force: true });
    if (config !== undefined) {
      write(path.join(sb.project, file), config);
    }
    return baselineLookup(addFolder(sb.project), sb.project);
  };
  const OFF = { kind: "off" };
  const UNSET = { kind: "off", unset: true };

  it("a missing key, an empty file and a missing config all mean no baseline", () => {
    assert.deepEqual(lookup(undefined), UNSET);
    assert.deepEqual(lookup(""), UNSET);
    assert.deepEqual(lookup("paths:\n  - lib\n"), UNSET);
  });

  it("names the file the key gives, quoted or not, with a comment", () => {
    assert.deepEqual(lookup("baseline: .rigor-baseline.yml\n"), { kind: "file", rel: ".rigor-baseline.yml" });
    assert.deepEqual(lookup('baseline: "my baseline.yml"\n'), { kind: "file", rel: "my baseline.yml" });
    assert.deepEqual(lookup("baseline: 'b.yml'\n"), { kind: "file", rel: "b.yml" });
    assert.deepEqual(lookup("baseline:   b.yml   # shared\n"), { kind: "file", rel: "b.yml" });
    assert.deepEqual(lookup("paths: [lib]\nbaseline: b.yml\nstrict: true\n"), { kind: "file", rel: "b.yml" });
  });

  it("a key that is not at the top level is not the baseline", () => {
    assert.deepEqual(lookup("report:\n  baseline: b.yml\n"), UNSET);
  });

  it("null and false spellings mean off, in any case", () => {
    for (const v of ["null", "~", "false", "no", "off", "NULL", "False", "NO", "Off"]) {
      assert.deepEqual(lookup(`baseline: ${v}\n`), OFF, v);
    }
  });

  it("a bare key, or one followed by a comment, is null: off, but set", () => {
    assert.deepEqual(lookup("baseline:\n"), OFF);
    assert.deepEqual(lookup("baseline: # none\n"), OFF);
    assert.deepEqual(lookup("baseline:\nstrict: true\n"), OFF);
  });

  it("a quoted \"false\" is kept as off", () => {
    assert.deepEqual(lookup('baseline: "false"\n'), OFF);
    assert.deepEqual(lookup("baseline: 'off'\n"), OFF);
    assert.deepEqual(lookup('baseline: ""\n'), OFF);
  });

  it("a name that merely starts with a falsy word is a file", () => {
    assert.deepEqual(lookup("baseline: nothing.yml\n"), { kind: "file", rel: "nothing.yml" });
    assert.deepEqual(lookup("baseline: offline.yml\n"), { kind: "file", rel: "offline.yml" });
  });

  it("a block scalar on the next indented line is ambiguous, CRLF and comments between included", () => {
    assert.deepEqual(lookup("baseline:\n  custom.yml\n"), { kind: "ambiguous" });
    assert.deepEqual(lookup("baseline:\r\n  custom.yml\r\n"), { kind: "ambiguous" });
    assert.deepEqual(lookup("baseline: # c\n\n# note\n\tcustom.yml\n"), { kind: "ambiguous" });
    assert.deepEqual(lookup("baseline:\r\n\r\n  custom.yml\r\n"), { kind: "ambiguous" });
  });

  it("an indented comment after a bare key is not a value", () => {
    assert.deepEqual(lookup("baseline:\n  # custom.yml\nstrict: true\n"), OFF);
    assert.deepEqual(lookup("baseline:\r\n  # custom.yml\r\nstrict: true\r\n"), OFF);
  });

  it("includes: makes it ambiguous, whatever baseline says", () => {
    assert.deepEqual(lookup("includes:\n  - base.yml\n"), { kind: "ambiguous" });
    assert.deepEqual(lookup("includes: [base.yml]\nbaseline: b.yml\n"), { kind: "ambiguous" });
    assert.deepEqual(lookup("baseline: b.yml\nincludes:\n  - base.yml\n"), { kind: "ambiguous" });
    assert.deepEqual(lookup("includes : [base.yml]\n"), { kind: "ambiguous" });
  });

  it("an empty includes list is not", () => {
    assert.deepEqual(lookup("includes: []\nbaseline: b.yml\n"), { kind: "file", rel: "b.yml" });
    assert.deepEqual(lookup("includes: [ ]  # none\nbaseline: b.yml\n"), { kind: "file", rel: "b.yml" });
    assert.deepEqual(lookup("includes: []\n"), UNSET);
  });

  it("a nested includes is not the top-level one", () => {
    assert.deepEqual(lookup("x:\n  includes: [a]\nbaseline: b.yml\n"), { kind: "file", rel: "b.yml" });
  });

  it("reads .rigor.dist.yml when there is no .rigor.yml, and .rigor.yml first", () => {
    assert.deepEqual(lookup("baseline: d.yml\n", ".rigor.dist.yml"), { kind: "file", rel: "d.yml" });
    write(path.join(sb.project, ".rigor.yml"), "baseline: y.yml\n");
    assert.deepEqual(baselineLookup(addFolder(sb.project), sb.project), { kind: "file", rel: "y.yml" });
  });

  it("reads the file rigor.server.configPath names, instead", () => {
    write(path.join(sb.project, ".rigor.yml"), "baseline: y.yml\n");
    write(path.join(sb.project, "ci.yml"), "baseline: ci.yml\n");
    stub.reset();
    stub.set("rigor.server.configPath", "ci.yml");
    assert.deepEqual(baselineLookup(addFolder(sb.project), sb.project), { kind: "file", rel: "ci.yml" });
  });
});

describe("parseRuleList", () => {
  it("reads an array and the { rules } form", () => {
    const rows = [{ id: "a.b", summary: "S" }, { id: "c" }];
    const expected = [
      { id: "a.b", summary: "S" },
      { id: "c", summary: "" },
    ];
    assert.deepEqual(parseRuleList(JSON.stringify(rows)), expected);
    assert.deepEqual(parseRuleList(JSON.stringify({ rules: rows })), expected);
  });

  it("an empty list is an empty rule set, not a failure", () => {
    assert.deepEqual(parseRuleList("[]"), []);
    assert.deepEqual(parseRuleList('{"rules":[]}'), []);
  });

  it("is undefined for output that is not a rule list", () => {
    assert.equal(parseRuleList("not json"), undefined);
    assert.equal(parseRuleList(""), undefined);
    assert.equal(parseRuleList("null"), undefined);
    assert.equal(parseRuleList('"rules"'), undefined);
    assert.equal(parseRuleList('{"results":[]}'), undefined);
    assert.equal(parseRuleList('{"rules":"x"}'), undefined);
  });

  it("drops rows without a string id", () => {
    assert.deepEqual(parseRuleList('[{"id":1},"x",null,[],{"id":"ok","summary":3}]'), [{ id: "ok", summary: "" }]);
  });
});

describe("the lightbulb's rule cache", () => {
  interface Provider {
    provideCodeActions(
      document: unknown,
      range: unknown,
      context: { diagnostics: unknown[] },
      token: { isCancellationRequested: boolean },
    ): { title: string; command?: { arguments?: unknown[] } }[];
  }
  let counter: string;
  let gate: string;
  let fail: string;
  let rules: string;
  let out: ReturnType<typeof fakeOutput>;
  let provider: Provider;

  beforeEach(() => {
    const dir = path.join(sb.dir, "fake");
    counter = path.join(dir, "explain-runs");
    gate = path.join(dir, "gate");
    fail = path.join(dir, "fail");
    rules = path.join(dir, "rules.json");
    write(counter);
    write(rules, '[{"id":"foo","summary":"S"},{"id":"bar","summary":"B"}]');
    stub.set(
      "rigor.server.path",
      script(
        path.join(dir, "rigor"),
        `case "$1" in
  version) echo "rigor 0.4.7";;
  explain)
    echo run >> "${counter}"
    while [ -f "${gate}" ]; do sleep 0.02; done
    if [ -f "${fail}" ]; then echo broken >&2; exit 1; fi
    cat "${rules}";;
esac`,
      ),
    );
    write(path.join(sb.project, "a.rb"));
    addFolder(sb.project);
    out = fakeOutput();
    registerCommands(fakeContext(path.join(sb.dir, "storage"), ExtensionMode.Production), out as never);
    provider = registeredCodeActionProviders[registeredCodeActionProviders.length - 1] as Provider;
  });

  const runs = () => fs.readFileSync(counter, "utf8").split("\n").filter((l) => l).length;
  const diag = (code: unknown, source = "rigor") => ({ source, code });
  const ask = (diagnostics: unknown[], over: { cancelled?: boolean; scheme?: string } = {}) =>
    provider.provideCodeActions(
      { uri: over.scheme ? Uri.from({ scheme: over.scheme, path: "/a.rb" }) : Uri.file(path.join(sb.project, "a.rb")) },
      undefined,
      { diagnostics },
      { isCancellationRequested: over.cancelled ?? false },
    );
  const titles = (diagnostics: unknown[]) => ask(diagnostics).map((a) => a.title);
  /** The quiet load has finished once the CLI's stdout reached the log. */
  const loaded = async () => {
    await waitFor(() => out.lines.some((l) => l.startsWith("[")), "the rule list in the log");
    await new Promise((r) => setTimeout(r, 100));
  };
  const settle = () => new Promise((r) => setTimeout(r, 300));

  it("the first request offers nothing and starts one load; later ones offer known rules", async () => {
    assert.deepEqual(titles([diag("foo")]), []);
    await loaded();
    assert.equal(runs(), 1);
    assert.deepEqual(titles([diag("foo")]), ["Explain foo"]);
    assert.equal(runs(), 1, "the cache answered");
  });

  it("offers only rules rigor explain knows, once each, for rigor diagnostics", async () => {
    ask([diag("foo")]);
    await loaded();
    const actions = ask([
      diag("foo"),
      diag("foo"),
      diag({ value: "bar" }),
      diag("plugin.rule"),
      diag("foo", "other"),
      diag(undefined),
      diag(""),
    ]);
    assert.deepEqual(
      actions.map((a) => a.title),
      ["Explain foo", "Explain bar"],
    );
    assert.deepEqual(actions[0].command?.arguments, ["foo"]);
  });

  it("starts no load for a request without a rigor diagnostic", async () => {
    ask([diag("foo", "ruby")]);
    ask([]);
    await settle();
    assert.equal(runs(), 0);
  });

  it("starts no load when cancelled, outside a trusted workspace, or for a non-file document", async () => {
    ask([diag("foo")], { cancelled: true });
    stub.trusted = false;
    ask([diag("foo")]);
    stub.trusted = true;
    ask([diag("foo")], { scheme: "untitled" });
    await settle();
    assert.equal(runs(), 0);
  });

  it("shares one in-flight load per root", async () => {
    write(gate);
    ask([diag("foo")]);
    await waitFor(() => runs() === 1, "the first run");
    ask([diag("foo")]);
    ask([diag("bar")]);
    await settle();
    assert.equal(runs(), 1);
    fs.rmSync(gate);
    await loaded();
    assert.deepEqual(titles([diag("foo")]), ["Explain foo"]);
    assert.equal(runs(), 1);
  });

  it("caches a failed load until clearRuleCache: nothing offered, nothing re-run", async () => {
    write(fail);
    ask([diag("foo")]);
    await waitFor(() => out.lines.some((l) => /explain rule list unavailable \(exit 1\)/.test(l)), "the failure log");
    assert.deepEqual(titles([diag("foo")]), []);
    ask([diag("foo")]);
    await settle();
    assert.equal(runs(), 1);

    fs.rmSync(fail);
    clearRuleCache();
    ask([diag("foo")]);
    await waitFor(() => runs() === 2, "a second load");
    await loaded();
    await settle();
    assert.deepEqual(titles([diag("foo")]), ["Explain foo"]);
  });

  it("output that is not a rule list is a cached failure too", async () => {
    write(rules, "this is not json");
    ask([diag("foo")]);
    await waitFor(() => out.lines.some((l) => /output is not a rule list/.test(l)), "the failure log");
    assert.deepEqual(titles([diag("foo")]), []);
    await settle();
    assert.equal(runs(), 1);
  });

  it("a load that clearRuleCache overtook does not fill the cache", async () => {
    write(rules, '[{"id":"foo","summary":"S"}]');
    write(gate);
    ask([diag("foo")]);
    await waitFor(() => runs() === 1, "the first run");
    clearRuleCache();
    fs.rmSync(gate);
    await loaded();
    // The old gem's list was dropped: the next request loads again.
    write(gate);
    assert.deepEqual(titles([diag("foo")]), []);
    await waitFor(() => runs() === 2, "a reload");
    fs.rmSync(gate);
    await settle();
    assert.deepEqual(titles([diag("foo")]), ["Explain foo"]);
  });

  it("a failure that clearRuleCache overtook is not cached", async () => {
    write(gate);
    write(fail);
    ask([diag("foo")]);
    await waitFor(() => runs() === 1, "the first run");
    clearRuleCache();
    fs.rmSync(gate);
    await settle();
    fs.rmSync(fail);
    assert.deepEqual(titles([diag("foo")]), []);
    await waitFor(() => runs() === 2, "a reload");
    await settle();
    assert.deepEqual(titles([diag("foo")]), ["Explain foo"]);
  });
});
