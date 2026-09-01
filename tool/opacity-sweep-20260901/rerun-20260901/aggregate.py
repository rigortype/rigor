#!/usr/bin/env python3
"""Aggregate the re-run opacity probe outputs and compare with the 2026-09-01 sweep."""
import json, glob, os, collections

SCRATCH = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(SCRATCH, "out")
PREV = os.path.join(SCRATCH, "prev")

targets = {}
for path in sorted(glob.glob(os.path.join(OUT, "*.json"))):
    name = os.path.basename(path)[:-5]
    with open(path) as f:
        targets[name] = json.load(f)

prev = {}
for path in sorted(glob.glob(os.path.join(PREV, "*.summary.json"))):
    name = os.path.basename(path).replace(".summary.json", "")
    with open(path) as f:
        prev[name] = json.load(f)

print("== Per-target precision: prev sweep (pre-campaign, under-seeded lens) vs now (full lens, post-campaign)")
print(f"{'target':44} {'files':>5} {'exprs':>7} {'prev':>7} {'prev_full':>9} {'now':>7} {'d_full':>7}")
for name, d in sorted(targets.items(), key=lambda kv: -(kv[1].get("total") or 0)):
    p = prev.get(name, {})
    pf = p.get("precision_fullseed")
    pp = p.get("precision")
    now = d.get("precision_ratio")
    base = pf if pf is not None else pp
    delta = (now - base) if (now is not None and base is not None) else None
    print(f"{name:44} {d.get('files',0):>5} {d.get('total',0):>7} "
          f"{pp if pp is not None else '-':>7} {pf if pf is not None else '-':>9} "
          f"{now:>7} {('%+.4f' % delta) if delta is not None else '-':>7}")

tot_exprs = sum(d.get("total", 0) for d in targets.values())
tot_precise = sum(d.get("precise", 0) for d in targets.values())
print(f"\ncorpus total: {tot_exprs} exprs, weighted precision {tot_precise/tot_exprs:.4f}" if tot_exprs else "")

print("\n== Aggregate opaque node classes (all targets)")
nodes = collections.Counter()
for d in targets.values():
    for k, v in d.get("opaque_node_classes", {}).items():
        nodes[k] += v
opaque_total = sum(nodes.values())
for k, v in nodes.most_common(18):
    print(f"  {k:42} {v:>7}  {100*v/opaque_total:5.1f}%")
print(f"  {'TOTAL opaque':42} {opaque_total:>7}")

print("\n== Local-read buckets / call receiver tiers (all targets)")
lb = collections.Counter(); ct = collections.Counter()
for d in targets.values():
    for k, v in d.get("local_read_buckets", {}).items(): lb[k] += v
    for k, v in d.get("call_receiver_tiers", {}).items(): ct[k] += v
print("  local reads:", dict(lb.most_common()))
print("  call tiers: ", dict(ct.most_common()))

print("\n== Named-receiver-but-opaque pairs, aggregated (top 60)")
pairs = collections.Counter()
pair_targets = collections.defaultdict(set)
pair_examples = {}
for name, d in targets.items():
    for k, v in d.get("named_receiver_opaque_pairs", {}).items():
        pairs[k] += v["count"]
        pair_targets[k].add(name)
        pair_examples.setdefault(k, v["examples"][:1])
for k, v in pairs.most_common(60):
    ts = ",".join(sorted(pair_targets[k]))
    ts = ts if len(ts) <= 40 else ts[:37] + "..."
    print(f"  {v:>5}  {k[:80]:80}  [{ts}]")
print(f"  pairs total sites: {sum(pairs.values())}, distinct pairs: {len(pairs)}")

print("\n== Method-name view of named-receiver pairs (top 40, grouping by #method)")
methods = collections.Counter()
for k, v in pairs.items():
    m = k.rsplit("#", 1)[-1]
    methods[m] += v
for k, v in methods.most_common(40):
    print(f"  {v:>5}  #{k}")

print("\n== Implicit-self opaque sends (top 30 aggregated)")
imp = collections.Counter()
for d in targets.values():
    for k, v in d.get("implicit_self_methods_top", {}).items(): imp[k] += v
for k, v in imp.most_common(30):
    print(f"  {v:>5}  {k}")
