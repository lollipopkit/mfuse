/**
 * Refuse a build on a bun other than the pinned one.
 *
 * `--frozen-lockfile` is only reproducible if the runtime that parses `bun.lock` is the
 * one that produced it, and bun enforces neither `packageManager` nor `engines` itself —
 * so the pin is checked here, where the reproducible install actually happens.
 *
 * Written against Node's API rather than bun's globals so `bun run check` can type-check
 * it with the `@types/node` the build configs already use.
 */
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const manifestURL = new URL('../package.json', import.meta.url)
const manifest = JSON.parse(readFileSync(fileURLToPath(manifestURL), 'utf8'))
const pinned = manifest.packageManager?.split('@')[1]
const running = process.versions.bun

if (!pinned) {
  console.error('package.json has no `packageManager` pin to check against.')
  process.exit(1)
}

if (!running) {
  console.error('This build must run under bun; `process.versions.bun` is not set.')
  process.exit(1)
}

if (running !== pinned) {
  console.error(
    `This project pins bun ${pinned}, and you are running ${running}.\n` +
      `Switch bun versions, or update "packageManager" in website/package.json and\n` +
      `re-resolve bun.lock in the same commit.`,
  )
  process.exit(1)
}
