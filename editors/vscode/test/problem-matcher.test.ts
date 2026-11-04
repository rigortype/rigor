// The `$rigor` problem matcher that package.json contributes, run as VS Code
// runs it: one JavaScript regular expression per output line.

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, it } from "node:test";

interface Pattern {
  regexp: string;
  file: number;
  line: number;
  column: number;
  severity: number;
  message: number;
  code: number;
}

const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "package.json"), "utf8"));
const matcher = manifest.contributes.problemMatchers.find((m: { name: string }) => m.name === "rigor");
const pattern: Pattern = matcher.pattern;
const re = new RegExp(pattern.regexp);

function match(line: string) {
  const m = re.exec(line);
  if (!m) {
    return undefined;
  }
  return {
    file: m[pattern.file],
    line: m[pattern.line],
    column: m[pattern.column],
    severity: m[pattern.severity],
    message: m[pattern.message],
    code: m[pattern.code],
  };
}

describe("the $rigor problem matcher", () => {
  it("reads file, position, severity, message and rule", () => {
    assert.deepEqual(match("lib/a.rb:3:7: error: Undefined method foo [undefined-method]"), {
      file: "lib/a.rb",
      line: "3",
      column: "7",
      severity: "error",
      message: "Undefined method foo",
      code: "undefined-method",
    });
  });

  it("the rule is optional", () => {
    const m = match("lib/a.rb:1:1: warning: something odd");
    assert.equal(m?.message, "something odd");
    assert.equal(m?.code, undefined);
    assert.equal(m?.severity, "warning");
    assert.equal(match("a.rb:1:1: info: fyi")?.severity, "info");
  });

  it("the last bracket is the rule", () => {
    const m = match("a.rb:2:5: error: expected Array [String] but got Hash [Integer] [argument-type]");
    assert.equal(m?.code, "argument-type");
    assert.equal(m?.message, "expected Array [String] but got Hash [Integer]");
  });

  it("a trailing bracket that is not a single token is part of the message", () => {
    const m = match("a.rb:2:5: error: bad value [not a rule]");
    assert.equal(m?.code, undefined);
    assert.equal(m?.message, "bad value [not a rule]");
    assert.equal(match("a.rb:1:1: error: got Hash[Symbol, Integer]")?.code, undefined);
  });

  it("a bracket glued to the message is not a rule", () => {
    const m = match("a.rb:1:1: error: expected Array[String]");
    assert.equal(m?.code, undefined);
    assert.equal(m?.message, "expected Array[String]");
  });

  it("reads a Windows drive path whole", () => {
    const m = match("C:\\work\\app\\lib\\a.rb:12:3: error: boom [rule-x]");
    assert.equal(m?.file, "C:\\work\\app\\lib\\a.rb");
    assert.equal(m?.line, "12");
    assert.equal(m?.code, "rule-x");
    assert.equal(match("C:/work/a.rb:1:2: warning: w")?.file, "C:/work/a.rb");
  });

  it("a path with a colon-free spaced directory still matches", () => {
    assert.equal(match("my app/lib/a.rb:1:1: error: x")?.file, "my app/lib/a.rb");
  });

  it("does not match the summary or the stats lines", () => {
    for (const line of [
      "3 error(s) in 2 file(s)",
      "No diagnostics",
      "",
      "Check targets",
      "  Ruby source files: 12",
      "Type universe (symbol discovery; not analyzed for diagnostics)",
      "  RBS classes available: 1304",
      "    bundled (core+stdlib+gems): 1290",
    ]) {
      assert.equal(match(line), undefined, JSON.stringify(line));
    }
  });

  it("does not match the CLI's own stderr lines", () => {
    for (const line of [
      "rigor: unknown option --nope",
      "rigor: .rigor.yml: invalid configuration",
      "Ignoring rigortype-0.4.7 because its extensions are not built.",
      "could not run Rigor: no `rigor` was found",
    ]) {
      assert.equal(match(line), undefined, line);
    }
  });

  it("needs a line, a column and a known severity", () => {
    assert.equal(match("a.rb:1: error: no column"), undefined);
    assert.equal(match("a.rb:1:1: fatal: unknown severity"), undefined);
    assert.equal(match("a.rb:x:1: error: line is not a number"), undefined);
    assert.equal(match("a.rb:1:1:error: no space after the colon"), undefined);
  });

  it("a rule-like token holding a bracket is not the rule", () => {
    const m = match("a.rb:1:1: error: msg [a[b]");
    assert.equal(m?.code, undefined);
    assert.equal(m?.message, "msg [a[b]");
  });

  it("a message that contains a position keeps the first one as the location", () => {
    const m = match("a.rb:1:2: error: see b.rb:3:4: error: x [r]");
    assert.equal(m?.file, "a.rb");
    assert.equal(m?.line, "1");
    assert.equal(m?.column, "2");
    assert.equal(m?.message, "see b.rb:3:4: error: x");
    assert.equal(m?.code, "r");
  });
});
