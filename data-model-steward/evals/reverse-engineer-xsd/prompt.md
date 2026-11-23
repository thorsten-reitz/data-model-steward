---
tags: [data-model-steward]
max_turns: 60
timeout_seconds: 1200
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

Our partners send us air quality data using the attached XSD (version 2.1). We're building a REST API and want a canonical data model behind it, so we can generate both the XSD-compatible structure and a JSON Schema for the API from one place. Please reverse-engineer the XSD into a data model, flag anything that's ambiguous or questionable in the XSD, and generate the JSON Schema. Each station produces about 24 hourly values per pollutant per day, ~400 stations, 6 pollutants. Just go ahead with your best judgement — I'll review afterwards.

Input files: observations.xsd
