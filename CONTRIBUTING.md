# Contributing

## Branching

- `master` is the protected release branch.
- `dev` is the integration branch — feature branches target `dev`, never `master`.
- Feature branches: `feat/ln-XXX-short-name`, `fix/ln-XXX-...`, `support/ln-XXX-...`, `docs/ln-XXX-...`.

## Commits

Conventional Commits, lowercase imperative subjects:

```
feat(jira): add inline edit picker
fix(detox): handle empty SEED gracefully
support(ci): add lua-check matrix
```

## Tests

```
make test
```

Runs the plenary spec suite via headless nvim.

## Lint

Lua formatted with [stylua](https://github.com/JohnnyMorganz/StyLua):

```
stylua --check lua/ tests/
```