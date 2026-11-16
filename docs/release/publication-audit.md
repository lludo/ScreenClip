# Publication audit

Updated November 15, 2026. **The repository remains private.** The branch-history cleanup is complete; GitHub's retained pull-request refs still prevent safe public publication.

## Completed history cleanup

Using git-filter-repo 2.47.0 with `--sensitive-data-removal`, we removed:

- Every historical path under `Fixtures/ScreenshotData/`, including the real queue database and its captured images.
- The six original real popup-image blobs, across all paths that referenced those blobs.

The scrubbed mirror contains no reachable fixture paths or flagged blobs. The rewritten `main` was pushed with an exact commit lease. Its tip tree matched the original tree, including the concurrently merged retest-notification screenshot update. Every other remote and local branch was deleted. Linked worktrees were preserved with detached heads.

The rewrite changed commit IDs and removed historical signatures. Existing clones must use the cleaned history; merging old history back would reintroduce removed objects. Detached worktrees remain local and must not push their old ancestry.

## GitHub cleanup still required

GitHub owns read-only `refs/pull/*` references. Rewriting branches and deleting source branches does not delete these refs or cached commit views.

GitHub-retained pull-request refs still contain removed personal data. Keep the repository private until GitHub has purged the affected references and cached objects.

GitHub's required server-side procedure is documented in [Removing sensitive data from a repository](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).

## Current content and release gates

- `Fixtures/ScreenshotData/` remains gitignored. Demo fixtures are generated rather than copied from a real queue.
- Some current marketing screenshots contain real app reports and were intentionally approved for sharing by the owner. The history cleanup does not replace those current assets. Review new screenshots before committing them.
- No signing credentials are committed. Local signing configuration and release outputs are ignored.
- The latest Release app and DMG passed Developer ID signing, Apple notarization, ticket stapling, and Gatekeeper verification. Reusable notarization credentials are stored in the macOS Keychain.
- Public source and download URLs remain disabled on the website until the repository is safe to publish and the notarized asset is available.

See [v1.0.0 readiness](v1.0.0-status.md) for the release state.
