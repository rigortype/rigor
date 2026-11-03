import json, os, collections
D = os.path.dirname(os.path.abspath(__file__))
def load(p):
    t = open(p, encoding="utf-8").read()
    j = json.loads(t[t.find("{"):])
    return [(d["path"], d["line"], d["column"], d["rule"], d["message"], d["severity"]) for d in j["diagnostics"]]
for c in ("masto", "lib", "redmine"):
    b, m = os.path.join(D, c + "_base.out"), os.path.join(D, c + "_memo.out")
    if not (os.path.exists(b) and os.path.exists(m)):
        continue
    db, dm = load(b), load(m)
    sb, sm = collections.Counter(db), collections.Counter(dm)
    rules = collections.Counter(r[3] for r in db)
    print(f"{c}: base={len(db)} memo={len(dm)} same_order={db == dm} removed={sum((sb - sm).values())} added={sum((sm - sb).values())}")
    print("  top rules:", rules.most_common(8))
    for r in list((sb - sm).elements())[:10]: print("  -", r)
    for r in list((sm - sb).elements())[:10]: print("  +", r)
    for arm in ("base", "memo"):
        j = json.load(open(os.path.join(D, f"{c}_{arm}.json")))
        print(f"  {arm}: cpu={round(sum(j['excl_cpu_s'].values()),2)} allocs={j['allocations']:,}")
