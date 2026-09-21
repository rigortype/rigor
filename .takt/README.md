# TAKT workflows (Rigor)

Project workflows for evaluating ADR-115 long quality-stable loops.

## `rigor-ready-for-agent`

Flow: **plan → develop → ship (draft PR) → watch CI → adversarial review → fix → (back to CI)**.

```bash
takt -i <n> -w rigor-ready-for-agent --provider claude
# or queue then:
takt run
```

Validate:

```bash
takt workflow doctor rigor-ready-for-agent
```

Provider/model binding per role can later move to `.takt/runtime.yaml`.
