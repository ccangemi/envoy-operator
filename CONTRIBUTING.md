# Contributing

Thank you for your interest in this project.

## Developer Certificate of Origin (DCO)

Every commit must have a `Signed-off-by` line. The line states that you wrote
the change, or that you have the right to submit it under the project license.
See <https://developercertificate.org/> for the full text.

Use `git commit -s` to add the line automatically:

```
Signed-off-by: Your Name <your.email@example.com>
```

The name and email must match the commit author.

## How to propose a change

1. Fork the repository and create a feature branch from `main`, for example
   `feature/short-description`.
2. Make small commits. Each commit does one thing.
3. Write commit messages in the
   [Conventional Commits](https://www.conventionalcommits.org/) style, for
   example `feat(chart): refuse a namespaceOverride`.
4. Run `make check` before you push. It runs the offline checks of the CI.
   The CI also runs `make chart-check`, which needs network access.
5. Open a pull request against `main`. Describe what the change does and how
   you tested it.

## Language

Write documentation, comments and commit messages in clear English. Use short
sentences and common technical words, so that non-native speakers can read
them easily.
