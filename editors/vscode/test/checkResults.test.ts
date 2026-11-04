// The `rigor check` output parser and the per-folder results index.

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, it } from "node:test";

import { CHECK_LINE_PATTERN, LineSplitter, parseCheckLine } from "../src/checkOutput";
import { CheckResults, collectionSink, createCheckCollection, groupFindings } from "../src/checkResults";
import { DiagnosticSeverity } from "./vscode-stub";

const ROOT = "/work/app";

describe("parseCheckLine", () => {
  it("reads position, severity, message and rule; positions become 0-based", () => {
    assert.deepEqual(parseCheckLine("/abs/a.rb:3:7: error: Undefined method foo [undefined-method]", ROOT), {
      file: "/abs/a.rb",
      line: 2,
      column: 6,
      severity: "error",
      message: "Undefined method foo",
      rule: "undefined-method",
    });
  });

  it("the rule is optional", () => {
    const f = parseCheckLine("/a.rb:1:1: warning: odd", ROOT);
    assert.equal(f?.rule, undefined);
    assert.equal(f?.message, "odd");
    assert.equal(f?.severity, "warning");
    assert.equal(parseCheckLine("/a.rb:1:1: info: fyi", ROOT)?.severity, "info");
  });

  it("the last bracket is the rule", () => {
    const f = parseCheckLine("/a.rb:2:5: error: want Array [String] got Hash [Integer] [argument-type]", ROOT);
    assert.equal(f?.rule, "argument-type");
    assert.equal(f?.message, "want Array [String] got Hash [Integer]");
  });

  it("ignores a trailing CR", () => {
    const f = parseCheckLine("/a.rb:1:1: error: boom [r]\r", ROOT);
    assert.equal(f?.rule, "r");
    assert.equal(f?.message, "boom");
  });

  it("keeps an absolute path as given, including a Windows drive path", () => {
    assert.equal(parseCheckLine("/abs/a.rb:1:1: error: x", ROOT)?.file, "/abs/a.rb");
    assert.equal(parseCheckLine("C:\\work\\a.rb:1:1: error: x", ROOT)?.file, "C:\\work\\a.rb");
  });

  it("resolves a relative path against the project root", () => {
    assert.equal(parseCheckLine("lib/a.rb:1:1: error: x", ROOT)?.file, path.resolve(ROOT, "lib/a.rb"));
    assert.equal(parseCheckLine(".rigor.yml:1:1: error: x", "/w/app/sub")?.file, path.resolve("/w/app/sub", ".rigor.yml"));
  });

  it("ignores summary, statistics and stderr lines", () => {
    for (const line of ["3 error(s) in 2 file(s)", "No diagnostics", "", "  Ruby source files: 12", "rigor: unknown option"]) {
      assert.equal(parseCheckLine(line, ROOT), undefined, line);
    }
  });

  it("uses the same pattern as the contributed $rigor matcher", () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "package.json"), "utf8"));
    const matcher = manifest.contributes.problemMatchers.find((m: { name: string }) => m.name === "rigor");
    assert.equal(CHECK_LINE_PATTERN, matcher.pattern.regexp);
  });
});

describe("LineSplitter", () => {
  it("joins a line split across chunks and flushes the unterminated tail", () => {
    const s = new LineSplitter();
    assert.deepEqual(s.push("a:1:1: er"), []);
    assert.deepEqual(s.push("ror: x\nsecond\nthi"), ["a:1:1: error: x", "second"]);
    assert.deepEqual(s.flush(), ["thi"]);
    assert.deepEqual(s.flush(), []);
  });
});

describe("groupFindings", () => {
  it("builds diagnostics with the check source, severity and rule", () => {
    const f = parseCheckLine("/a.rb:4:2: info: hi [rule-a]", ROOT)!;
    const w = parseCheckLine("/a.rb:5:1: warning: w", ROOT)!;
    const e = parseCheckLine("/a.rb:6:1: error: e", ROOT)!;
    const d = groupFindings([f, w, e]).get("/a.rb")!;
    assert.equal(d.length, 3);
    assert.equal(d[0].source, "rigor check");
    assert.equal(d[0].code, "rule-a");
    assert.equal(d[0].severity, DiagnosticSeverity.Information);
    assert.equal(d[0].range.start.line, 3);
    assert.equal(d[0].range.start.character, 1);
    assert.equal(d[1].severity, DiagnosticSeverity.Warning);
    assert.equal(d[1].code, undefined);
    assert.equal(d[2].severity, DiagnosticSeverity.Error);
  });
});

describe("CheckResults", () => {
  const setup = () => {
    const published = new Map<string, string[]>();
    const results = new CheckResults<string>({
      set: (file, d) => void published.set(file, d),
      delete: (file) => void published.delete(file),
    });
    return { published, results };
  };
  const run = (...pairs: [string, string[]][]) => new Map(pairs);

  it("a run for folder B keeps folder A's results", () => {
    const { published, results } = setup();
    results.replace("A", run(["/a/x.rb", ["a1"]]));
    results.replace("B", run(["/b/y.rb", ["b1"]]));
    assert.deepEqual([...published.keys()].sort(), ["/a/x.rb", "/b/y.rb"]);
  });

  it("a re-run of A replaces only A's files, including files it no longer reports", () => {
    const { published, results } = setup();
    results.replace("A", run(["/a/x.rb", ["a1"]], ["/a/z.rb", ["a2"]]));
    results.replace("B", run(["/b/y.rb", ["b1"]]));
    results.replace("A", run(["/a/x.rb", ["a3"]]));
    assert.deepEqual(published.get("/a/x.rb"), ["a3"]);
    assert.equal(published.has("/a/z.rb"), false);
    assert.deepEqual(published.get("/b/y.rb"), ["b1"]);
  });

  it("a file two folders report holds both folders' findings", () => {
    const { published, results } = setup();
    results.replace("A", run(["/shared.rb", ["a"]]));
    results.replace("B", run(["/shared.rb", ["b"]]));
    assert.deepEqual(published.get("/shared.rb"), ["a", "b"]);
    results.replace("A", run(["/shared.rb", ["a2"]]));
    assert.deepEqual(published.get("/shared.rb"), ["a2", "b"]);
    results.clear("B");
    assert.deepEqual(published.get("/shared.rb"), ["a2"]);
  });

  it("clear drops one folder, clearAll every folder", () => {
    const { published, results } = setup();
    results.replace("A", run(["/a.rb", ["a"]]));
    results.replace("B", run(["/b.rb", ["b"]]));
    results.clear("A");
    assert.deepEqual([...published.keys()], ["/b.rb"]);
    assert.deepEqual(results.folders(), ["B"]);
    results.clearAll();
    assert.equal(published.size, 0);
    assert.deepEqual(results.folders(), []);
  });

  it("publishes into a DiagnosticCollection by file", () => {
    const collection = createCheckCollection() as unknown as { name: string; entries: Map<string, unknown[]> };
    const results = new CheckResults(collectionSink(collection as never));
    results.replace("A", groupFindings([parseCheckLine("/a.rb:1:1: error: x", ROOT)!]));
    assert.equal(collection.name, "rigor check");
    assert.equal(collection.entries.get("/a.rb")?.length, 1);
    results.clear("A");
    assert.equal(collection.entries.size, 0);
  });
});
