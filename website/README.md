# MFuse website

Svelte 5 + Vite + Tailwind, built with bun.

```bash
bun install && bun run dev
bun run check           # tsc --noEmit against both jsconfig files (checkJs)
bun run build           # install --frozen-lockfile, then check, then vite build
```

`bun run check` covers every `.js` and `.ts` file here, including the generated
`src/i18n/` modules. `.svelte` files are not type-checked — see below.

Two projects, because TypeScript applies global declarations program-wide:
`jsconfig.json` is the browser app, `jsconfig.node.json` is `vite.config.js` plus
`svelte.config.js` and is the only one given `@types/node`. Merging them would make
`process` and `Buffer` type-check in browser code that cannot use them.

`packageManager` pins the bun release the committed `bun.lock` was produced with. bun
enforces neither that field nor `engines`, so `bun run build` checks it itself
(`scripts/check-bun-version.js`) and refuses to run a frozen install under a different
runtime. `bun install` and `bun run dev` are left unguarded. To move the pin, change
`packageManager` and re-resolve `bun.lock` in the same commit.

## Editing translations

Translation sources are `src/i18n/<locale>/index.ts`; everything else under `src/i18n/`
is generated and committed.

`en` is the base locale (`.typesafe-i18n.json`), which is what the generated types are
derived from: **a new key goes into `src/i18n/en/index.ts` first**, and only then into the
other locales. Adding it elsewhere first leaves it out of `Translation`, so the locale
that has it fails `bun run check` as an unknown property.

The `typesafe-i18n` script in `package.json` **cannot regenerate the output in this
project**: `typesafe-i18n@5.27.1` calls `ts.createProgram`, which the TypeScript 7 API no
longer exposes, so it crashes against the manifest's TypeScript.

Regenerate with a pinned generator that lives outside this project, so neither
`package.json` nor `bun.lock` is touched (installing TypeScript 6 here would silently
revert the TypeScript 7 migration, and a half-restored manifest breaks the frozen build):

```bash
# 1. one-off toolchain, anywhere outside the repo
mkdir -p /tmp/mfuse-i18n && cd /tmp/mfuse-i18n
bun add --exact typesafe-i18n@5.27.1 typescript@5.9.3

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

## Checking `.svelte` files

`bun run check` does not reach them, so this is the manual pass — run it before merging a
change that touches a `.svelte` script block, since nothing else will catch a type error
in one:

```bash
# 1. one-off toolchain, anywhere outside the repo — same reasoning as the i18n generator
mkdir -p /tmp/mfuse-sveltecheck && cd /tmp/mfuse-sveltecheck
bun add --exact svelte-check@4.4.4 typescript@5.9.3 svelte@5.56.8

# 2. run it against this project
cd /path/to/mfuse/website
/tmp/mfuse-sveltecheck/node_modules/.bin/svelte-check --tsconfig ./jsconfig.json --threshold error

# 3. clean up
rm -rf /tmp/mfuse-sveltecheck
```

It reports `0 ERRORS` on a clean tree. Keeping `.svelte` script blocks thin — logic in
`src/lib/*.js`, which `bun run check` does cover — is what keeps this pass cheap.

Why it lives outside the project: `svelte-check@4.4.4` is happy with any TypeScript from
5.0 up *as an API*, and 5.9.3 is what the pins above use. It cannot drive this project's
TypeScript 7, which no longer exposes that API — pointed at it, svelte-check dies on
`ts.sys` being undefined, the same wall `typesafe-i18n` hits. Its `--tsgo` mode targets the
native compiler instead, but needs `@typescript/native-preview` installed.

**TODO:** fold this back into `bun run check` once `svelte-check` can run against a
TypeScript 7 install on its own.
