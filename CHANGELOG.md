# Changelog

All notable changes to wpc-migrate will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-10-26

### Added

- The new site runs on the LocalWP site's web server, nginx or Apache, and `--web-server` picks the other one. nginx needs a wpc whose `create` accepts `--web-server`.
- On nginx, the custom `.conf` files that LocalWP's `site.conf.hbs` includes, such as an uploads proxy, are copied to the new site's `nginx/` folder.
- Rules added straight into LocalWP's `site.conf.hbs`, such as an uploads proxy `location` block, go to the new site's `nginx/site-rules.conf`. `--dry-run` lists the file, and its JSON carries the rules.

### Changed

- The symlink prompt explains each answer (`m` mount, `c` copy, `s` skip) and that Enter picks the capitalized one. It says that a mounted link becomes an empty folder in the site's files, and the README explains how to repoint a mount after moving its folder.

### Fixed

- A `WP_ENVIRONMENT_TYPE` set to a plain string moves to the top of `wp-config.php`, so WordPress VIP sites, which allow `wp db` only in a `local` environment, no longer fail the import.

## [1.2.0] - 2026-10-23

### Changed

- The new site keeps the LocalWP site's domain, and turns on HTTPS when the LocalWP site's URL uses `https://`. `--domain` picks a different domain.

## [1.1.0] - 2026-10-23

### Added

- `--symlinks skip` and a skip answer leave a symlink out of the new site.
- Without `--symlinks`, each symlink to a path outside the site is asked about separately, and the prompt says whether it points to a file or a folder.

### Fixed

- Absolute symlinks that point inside the site, such as Query Monitor's `db.php` drop-in, stay links in the new site, rewritten as relative links.
- A must-use plugin or drop-in that is a relative symlink is put back after the first start.

## [1.0.0] - 2026-10-21

### Added

- `wpc-migrate localwp list` lists LocalWP sites with their status, PHP version, database, and multisite mode.
- `wpc-migrate localwp <site>` moves a LocalWP site into a new wp-container site: files, database, URLs, PHP version, multisite mode, and add-ons.
- Stopped LocalWP sites are exported through a temporary MySQL server on an APFS clone of their data, so LocalWP does not need to be running.
- Symlinks to folders outside the site are bind-mounted or copied, chosen per run or with `--symlinks`.
- Subdomain networks get HTTPS on `<slug>.localhost`, and their `http://` links move to `https://`.
- Must-use plugins and drop-ins are set aside during wp-container's first-start install and restored before the import.
- `--dry-run` shows the migration plan without changing anything.

[Unreleased]: https://github.com/s3rgiosan/wpc-migrate/compare/1.3.0...HEAD
[1.3.0]: https://github.com/s3rgiosan/wpc-migrate/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/s3rgiosan/wpc-migrate/compare/1.1.0...1.2.0
[1.1.0]: https://github.com/s3rgiosan/wpc-migrate/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/s3rgiosan/wpc-migrate/releases/tag/1.0.0
