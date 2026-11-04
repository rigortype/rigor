// Policy for the folder lifecycle that needs no `vscode` or languageclient:
// when a folder whose server keeps timing out stops being restarted, how
// requests for a sync are merged, and when a start timeout is news. Kept
// apart from `extension.ts` so the unit tests can drive it.

/** Consecutive start timeouts after which a folder is no longer restarted. */
export const START_TIMEOUT_LIMIT = 2;

/**
 * Consecutive start timeouts per folder. Once a folder reaches
 * `START_TIMEOUT_LIMIT`, `skip` is true and automatic syncs leave it alone
 * (each try is another 60 s hang and toast). Everything the user or the
 * project can do to fix it must `reset` the folder; a skipped folder is
 * shown as an error until then.
 */
export class StartBackoff {
  private readonly counts = new Map<string, number>();
  private readonly noted = new Set<string>();

  /** A start timed out; returns the consecutive count. */
  recordTimeout(key: string): number {
    const count = (this.counts.get(key) ?? 0) + 1;
    this.counts.set(key, count);
    return count;
  }

  /** A start succeeded. */
  recordSuccess(key: string): void {
    this.reset(key);
  }

  /** Whether the folder is being skipped. */
  skip(key: string): boolean {
    return (this.counts.get(key) ?? 0) >= START_TIMEOUT_LIMIT;
  }

  /** True the first time a skipped folder is reported since its last reset. */
  firstSkipNote(key: string): boolean {
    if (this.noted.has(key)) {
      return false;
    }
    this.noted.add(key);
    return true;
  }

  reset(key: string): void {
    this.counts.delete(key);
    this.noted.delete(key);
  }

  resetAll(): void {
    this.counts.clear();
    this.noted.clear();
  }

  /** Forget every folder that is not in `wanted` (it left or was removed). */
  retainOnly(wanted: ReadonlySet<string>): void {
    for (const key of [...this.counts.keys()]) {
      if (!wanted.has(key)) {
        this.reset(key);
      }
    }
  }
}

/**
 * Merges requests for a sync: while one is queued but has not started, a
 * further request joins it.
 *
 * Joining an earlier queued sync (instead of queueing behind later tasks)
 * is safe because every other queued task (a restart, a pin change, a
 * managed-runtime task) ends with the same sync, and a sync reads the
 * workspace state when it runs, not when it was requested.
 */
export class SyncCoalescer {
  private pending: Promise<void> | undefined;

  constructor(private readonly enqueue: (task: () => Promise<void>) => Promise<void>) {}

  request(sync: () => Promise<void>): Promise<void> {
    if (this.pending) {
      return this.pending;
    }
    const run = this.enqueue(() => {
      this.pending = undefined;
      return sync();
    });
    this.pending = run;
    void run.then(() => {
      if (this.pending === run) {
        this.pending = undefined;
      }
    });
    return run;
  }
}

/**
 * Whether a start timeout is worth a toast: not when the extension itself
 * already abandoned the client (deactivate, a restart) while it was starting.
 */
export function startTimeoutIsNews(alreadyAbandoned: boolean): boolean {
  return !alreadyAbandoned;
}

/** The sentence a start timeout toast ends with once the folder is given up on. */
export function backoffNotice(count: number): string {
  return count >= START_TIMEOUT_LIMIT
    ? "; not retrying automatically, run Rigor: Restart Server"
    : "";
}

/** The tooltip note of a folder that is being skipped. */
export const SKIPPED_NOTE =
  "not retried automatically after repeated start timeouts; run Rigor: Restart Server";
