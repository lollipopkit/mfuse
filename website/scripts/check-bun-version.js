/**
 * Refuse a build on a bun other than the pinned one.
 *
 * `--frozen-lockfile` is only reproducible if the runtime that parses `bun.lock` is the
 * one that produced it, and bun enforces neither `packageManager` nor `engines` itself —
 * so the pin is checked here, where the reproducible install actually happens.
 */
import pkg from '../package.json' with { type: 'json' }

const pinned = pkg.packageManager?.split('@')[1]

if (!pinned) {
  console.error('package.json has no `packageManager` pin to check against.')
  process.exit(1)
}

if (Bun.version !== pinned) {
  console.error(
    `This project pins bun ${pinned}, and you are running ${Bun.version}.\n` +
      `Switch bun versions, or update "packageManager" in website/package.json and\n` +
      `re-resolve bun.lock in the same commit.`,
  )
  process.exit(1)
}
