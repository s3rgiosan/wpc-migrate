# Releasing

1. On the release branch, rename `## [Unreleased]` in `CHANGELOG.md` to `## [x.y.z] - YYYY-MM-DD` and update the link references at the bottom: `[Unreleased]` compares `x.y.z...HEAD`, and `[x.y.z]` compares the previous version with `x.y.z`.
2. Set `WPCMigrateVersion.current` in `Sources/WPCMigrateKit/WPCMigrateVersion.swift` to `x.y.z`.
3. Commit as `chore: release x.y.z`, then squash-merge the pull request once CI passes.
4. Tag the merge commit on `main` and push the tag:

   ```sh
   git checkout main && git pull
   git tag -a x.y.z -m x.y.z
   git push origin x.y.z
   ```

   The Release workflow builds the arm64 binary, stops if `wpc-migrate --version` does not match the tag, and publishes the GitHub release with `wpc-migrate-macos-arm64.tar.gz`, its `.sha256`, and the version's CHANGELOG section as notes. To release a tag that already exists, run the workflow by hand with that tag.
5. Update the formula in [s3rgiosan/homebrew-tap](https://github.com/s3rgiosan/homebrew-tap): set the version in `url` in `Formula/wpc-migrate.rb` and set `sha256` to the hash in the release's `.sha256` file:

   ```sh
   curl -fsSL https://github.com/s3rgiosan/wpc-migrate/releases/download/x.y.z/wpc-migrate-macos-arm64.tar.gz.sha256
   ```

   Commit as `feat: update wpc-migrate to x.y.z` and push, then check the formula:

   ```sh
   brew update
   brew audit --strict s3rgiosan/tap/wpc-migrate
   brew upgrade s3rgiosan/tap/wpc-migrate || brew install s3rgiosan/tap/wpc-migrate
   brew test s3rgiosan/tap/wpc-migrate
   ```
