# MFuse website

Svelte 5 + Vite + Tailwind, built with bun.

```bash
bun install && bun run dev
bun run check           # tsc --noEmit against jsconfig.json (checkJs)
bun run build           # install --frozen-lockfile, then check, then vite build
```

`bun run check` covers `.js` and `.ts`, including the generated `src/i18n/` modules.
`.svelte` files are not type-checked — see below.

## Editing translations

Translation sources are `src/i18n/<locale>/index.ts`; everything else under `src/i18n/`
is generated and committed. The `typesafe-i18n` script in `package.json` **cannot
regenerate them in this project**: `typesafe-i18n@5.27.1` calls `ts.createProgram`, which
the TypeScript 7 API no longer exposes, so it crashes against the manifest's TypeScript.

Regenerate with a pinned generator that lives outside this project, so neither
`package.json` nor `bun.lock` is touched (installing TypeScript 6 here would silently
revert the TypeScript 7 migration, and a half-restored manifest breaks the frozen build):

```bash
# 1. one-off toolchain, anywhere outside the repo
mkdir -p /tmp/mfuse-i18n && cd /tmp/mfuse-i18n
bun add typesafe-i18n@5.27.1 typescript@5.9.3

# 2. run it from website/ — cwd is where it reads .typesafe-i18n.json and writes output
cd /path/to/mfuse/website
/tmp/mfuse-i18n/node_modules/.bin/typesafe-i18n --no-watch

# 3. verify: only the locale file you edited and its generated types should differ
git status --short src/i18n
git diff src/i18n
bun run check

# 4. clean up
rm -rf /tmp/mfuse-i18n
```

Those exact pins reproduce the committed artifacts byte for byte; a different TypeScript
release may format the output differently, so bump them deliberately, in their own commit.

**TODO:** drop this section and chain `bun run typesafe-i18n` into `build` once the
generator supports TypeScript 7.

**TODO:** `.svelte` files are not type-checked — `svelte-check` refuses a
TypeScript-7-only project, wanting TypeScript 6 installed alongside plus `--tsgo`. Add it
back to `bun run check` when it supports a single TypeScript 7 install.
