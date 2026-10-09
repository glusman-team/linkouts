<!--
Title: a conventional commit. feat: / fix: / refactor: / test: / docs: / perf: / chore:
Example: feat(kgs): add display config for infores:my-kp

Keep the diff small and focused. See CONTRIBUTING.md for what is contributor-facing
(the Go CLI in cli/ and deployment are not).
-->

## What changed and why

<!-- The outcome first: what a reader or a maintainer can do now that they could not before. -->

## How I verified it

<!-- Exact commands and their result. `make check` is the full offline gate and is what CI runs. -->

```sh
make check
```

Result:

<!-- For a display config only, this is enough: -->
<!-- make kgs-check   ->   all configs valid, golden fixtures render -->

## Visible UI text or HTML structure

<!-- Should be "no" unless that is the point of this PR. If yes, say which sentence or element and why. -->

- [ ] No visible UI text changed
- [ ] No HTML structure changed

## Risks and follow-ups

<!-- What could break, what you deliberately left out, what should come next. -->
