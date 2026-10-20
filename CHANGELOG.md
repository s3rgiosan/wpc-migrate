# Changelog

All notable changes to wpc-migrate will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `wpc-migrate localwp list` lists LocalWP sites with their status, PHP version, database, and multisite mode.
- `wpc-migrate localwp <site>` moves a LocalWP site into a new wp-container site: files, database, URLs, PHP version, multisite mode, and add-ons.
- Stopped LocalWP sites are exported through a temporary MySQL server on an APFS clone of their data, so LocalWP does not need to be running.
- Symlinks to folders outside the site are bind-mounted or copied, chosen per run or with `--symlinks`.
- Subdomain networks get HTTPS on `<slug>.localhost`, and their `http://` links move to `https://`.
- Must-use plugins and drop-ins are set aside during wp-container's first-start install and restored before the import.
- `--dry-run` shows the migration plan without changing anything.

[Unreleased]: https://github.com/s3rgiosan/wpc-migrate/commits/main
