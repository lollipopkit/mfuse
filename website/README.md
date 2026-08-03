# MFuse website

Svelte 5 + Vite + Tailwind, built with bun.

```bash
bun install && bun run dev
bun run check           # tsc --noEmit against jsconfig.json (checkJs)
bun run build           # install --frozen-lockfile, then check, then vite build
bun run typesafe-i18n   # regenerate src/i18n (see below)
```

## Known toolchain gaps

Both are consequences of the TypeScript 7 upgrade and should go away as the
tooling catches up:

- **TODO: `bun run typesafe-i18n` fails under TypeScript 7.** `typesafe-i18n@5.27.1`
  calls `ts.createProgram`, which the TypeScript 7 API no longer exposes. The
  generated files under `src/i18n/` are therefore committed and the build does
  *not* regenerate them; editing translations needs a temporary TypeScript 6
  install. Remove this note once the generator supports TypeScript 7.
- **TODO: `.svelte` files are not type-checked.** `svelte-check` refuses a
  TypeScript-7-only project — it wants TypeScript 6 alongside it plus `--tsgo` —
  so `bun run check` covers `.js`/`.ts` only. Add it back when it supports a
  single TypeScript 7 install.
