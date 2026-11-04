// The folder lifecycle policy of extension.ts: when a folder that keeps
// timing out is left alone, how sync requests merge, and when a start
// timeout is news.

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  START_TIMEOUT_LIMIT,
  StartBackoff,
  SyncCoalescer,
  backoffNotice,
  startTimeoutIsNews,
} from "../src/syncPolicy";

const timeOut = (b: StartBackoff, key: string, times = START_TIMEOUT_LIMIT): void => {
  for (let i = 0; i < times; i++) {
    b.recordTimeout(key);
  }
};

describe("StartBackoff", () => {
  it("skips a folder only after the limit of consecutive timeouts", () => {
    const b = new StartBackoff();
    assert.equal(b.skip("a"), false);
    b.recordTimeout("a");
    assert.equal(b.skip("a"), false);
    b.recordTimeout("a");
    assert.equal(b.skip("a"), true);
    assert.equal(b.skip("b"), false);
  });

  it("a successful start ends the run of timeouts", () => {
    const b = new StartBackoff();
    b.recordTimeout("a");
    b.recordSuccess("a");
    b.recordTimeout("a");
    assert.equal(b.skip("a"), false);
  });

  it("reset and resetAll lift the skip", () => {
    const b = new StartBackoff();
    timeOut(b, "a");
    timeOut(b, "b");
    b.reset("a");
    assert.equal(b.skip("a"), false);
    assert.equal(b.skip("b"), true);
    b.resetAll();
    assert.equal(b.skip("b"), false);
  });

  it("retainOnly forgets a folder that left, and keeps the others", () => {
    const b = new StartBackoff();
    timeOut(b, "a");
    timeOut(b, "b");
    b.retainOnly(new Set(["a"]));
    assert.equal(b.skip("a"), true);
    assert.equal(b.skip("b"), false);
  });

  it("notes a skipped folder once per run, and again after a reset", () => {
    const b = new StartBackoff();
    timeOut(b, "a");
    assert.equal(b.firstSkipNote("a"), true);
    assert.equal(b.firstSkipNote("a"), false);
    b.reset("a");
    timeOut(b, "a");
    assert.equal(b.firstSkipNote("a"), true);
  });
});

describe("SyncCoalescer", () => {
  /** A queue that runs one task at a time, as `enqueue` does. */
  function queue() {
    let tail: Promise<void> = Promise.resolve();
    const gates: (() => void)[] = [];
    const enqueue = (task: () => Promise<void>): Promise<void> => {
      tail = tail.then(task);
      return tail;
    };
    const blocker = (): void => {
      tail = tail.then(() => new Promise<void>((r) => gates.push(r)));
    };
    return { enqueue, blocker, release: () => gates.shift()!() };
  }

  it("a sync requested while one is queued joins it", async () => {
    const q = queue();
    const c = new SyncCoalescer(q.enqueue);
    let runs = 0;
    const sync = async (): Promise<void> => void runs++;
    q.blocker();
    const first = c.request(sync);
    const second = c.request(sync);
    await new Promise((r) => setImmediate(r));
    q.release();
    await Promise.all([first, second]);
    assert.equal(runs, 1);
  });

  it("a sync requested once the queued one started queues another", async () => {
    const q = queue();
    const c = new SyncCoalescer(q.enqueue);
    let runs = 0;
    let second: Promise<void> | undefined;
    const sync = async (): Promise<void> => {
      runs++;
      if (runs === 1) {
        second = c.request(sync);
      }
    };
    await c.request(sync);
    await second;
    assert.equal(runs, 2);
  });

  it("a later request runs again after the earlier finished", async () => {
    const q = queue();
    const c = new SyncCoalescer(q.enqueue);
    let runs = 0;
    await c.request(async () => void runs++);
    await c.request(async () => void runs++);
    assert.equal(runs, 2);
  });
});

describe("start timeout decisions", () => {
  it("a timeout of an already abandoned client is not news", () => {
    assert.equal(startTimeoutIsNews(true), false);
    assert.equal(startTimeoutIsNews(false), true);
  });

  it("only the timeout that reaches the limit says it is not retried", () => {
    assert.equal(backoffNotice(START_TIMEOUT_LIMIT - 1), "");
    assert.match(backoffNotice(START_TIMEOUT_LIMIT), /Restart Server/);
  });
});
