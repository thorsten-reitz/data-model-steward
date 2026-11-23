# Decisions

## D-001 Permit identifiers are UUIDs (2026-04-02)
Permits are exchanged with three municipal partner systems. Choice: UUID, stable across systems.

## D-002 Exchange format is JSON with closed content (2026-04-10)
Partners validate strictly against the JSON Schema of the release they implemented.
