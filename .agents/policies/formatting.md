# Formatting Policy

JavaScript formatting is owned by Prettier. Run Prettier only on changed JS
files unless the task is an intentional formatting-only commit. Keep behavior
changes separate from mechanical formatting.

To format changed JS from the repository root, inside Workshop or CI:

```bash
git diff --name-only -- '*.js' | xargs -r npx --yes prettier@3 --write --ignore-path .prettierignore
```

Use this non-mutating check for verification:

```bash
workshop run <project-alias> -- format-check
```

The lower-level command is:

```bash
cd tests && npm run format:check
```
