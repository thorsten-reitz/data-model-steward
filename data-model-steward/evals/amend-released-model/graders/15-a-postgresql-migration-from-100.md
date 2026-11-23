---
type: llm
focus: trace
weight: 1
---

A PostgreSQL migration from 1.0.0 is provided and is additive only: it adds tables, columns and constraints without dropping or rewriting existing data (any destructive step is left as an explicit manual step)
