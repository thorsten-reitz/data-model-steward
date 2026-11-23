---
type: llm
focus: trace
weight: 1
---

The rename of reference to fileNumber does not break 1.0.0 consumers: either fileNumber is added and reference deprecated, or reference is kept (relabelled or aliased as file number) and the rename is deferred to a major version and raised with the user
