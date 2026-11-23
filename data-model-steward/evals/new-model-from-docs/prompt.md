---
tags: [data-model-steward]
max_turns: 60
timeout_seconds: 1200
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

Hi! We need a proper data model for our new urban tree cadastre. The requirements doc and the dump of our legacy schema are attached. Target is PostgreSQL/PostGIS for the app, plus a JSON Schema for the monthly exchange file to the regional agency. I'm in meetings all day so I can't answer questions right now — please make sensible assumptions, write them down so I can check them later, and give me a complete first draft including the generated schemas. Put everything in a datamodel/ folder.

Input files: requirements.md, legacy_trees.sql
