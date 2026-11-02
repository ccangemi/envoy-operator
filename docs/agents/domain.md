# Domain Docs

How the engineering skills read the domain documentation of this repo.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root.
- **`docs/adr/`**: read the ADRs that touch the area you are about to work in.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a proposal, a hypothesis, a test name), use the term from `GLOSSARY.md`. Do not use the synonyms that the glossary lists under _Avoid_.

If the concept you need is not in the glossary, either you are inventing language that the project does not use (reconsider), or there is a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, say so explicitly. Do not override it silently:

> _Contradicts ADR-0005 (webhook bootstrap), but worth reopening because…_
