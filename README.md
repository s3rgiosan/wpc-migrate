# wpc-migrate

Move WordPress sites from [LocalWP](https://localwp.com) into [wp-container](https://github.com/fabiankaegy/wp-container) with one command.

```sh
wpc-migrate localwp list
wpc-migrate localwp "My Site"
```

wpc-migrate reads the LocalWP site's files and database, creates a wp-container site with the same PHP version, multisite mode, and add-ons, imports the database, and rewrites its URLs. LocalWP's files and database are only read, so the LocalWP site keeps working.

## Requirements

- macOS 14 or newer
- LocalWP, with the site you want to move
- The wp-container CLI (`wpc`) 0.3.0 or newer. Mounting linked folders needs a `wpc` whose `create` command accepts `--mount`; older versions copy those folders.

LocalWP does not need to be running. A stopped site's database is exported through a temporary MySQL server, started from LocalWP's own MySQL binaries on an APFS clone of the site's data.

## Install

```sh
git clone https://github.com/s3rgiosan/wpc-migrate.git
cd wpc-migrate
swift build -c release
install -m 0755 .build/release/wpc-migrate /usr/local/bin/wpc-migrate
```

## Usage

```sh
# List LocalWP sites with their status, PHP, database, and multisite mode.
wpc-migrate localwp list [--json]

# Show what a migration will do, without changing anything.
wpc-migrate localwp <site> --dry-run

# Migrate. <site> is a LocalWP site id, domain, or name.
wpc-migrate localwp <site> [options]
```

| Option | Description |
| --- | --- |
| `--name <name>` | Name for the new site. Defaults to the LocalWP site name. |
| `--path <dir>` | Parent folder for the new site. Defaults to wp-container's sites folder. |
| `--domain <host>` | Domain for the new site. Defaults to the LocalWP site's domain. |
| `--php-version <x.y>` | PHP version. Defaults to the LocalWP site's. |
| `--https` | Turn on HTTPS. It is on when the LocalWP site's URL uses `https://`. |
| `--no-mailpit` | Leave Mailpit off. It is on by default because every LocalWP site has it. |
| `--symlinks mount\|copy\|skip` | How to bring over every symlink to a path outside the site. Asked per link when omitted. |
| `--reset-admin` | Create or reset wp-container's `admin` / `password` login. Without it, the site keeps its LocalWP users. |
| `--dump <file>` | Import this `.sql` or `.sql.gz` dump instead of exporting from LocalWP. |
| `--source-url <url>` | The dump's site URL, when it can't be read from the database. |
| `--keep-dump` | Keep the exported dump in the new site's folder. |
| `--wpc <path>` | The `wpc` binary to use. Defaults to the one in `PATH`. |
| `--verbose` | Show wpc's own progress output. |
| `--json` | Print the result as JSON, and errors as `{error, detail}` on stderr. |

## What gets migrated

- **Files.** `app/public` is cloned into the new site's `wordpress/` folder.
- **Database.** The database is dumped with LocalWP's `mysqldump`. MySQL 8 `utf8mb4_0900_*` collations in table definitions are rewritten for MariaDB. Row data is left untouched.
- **URLs.** The new site keeps the LocalWP site's domain, and turns on HTTPS when the LocalWP site's URL uses `https://`. With `--domain` or `--https`, `wpc db import` rewrites the LocalWP URL to the new site's URL across all tables, including every site of a multisite network.
- **wp-config.php.** The database settings read wp-container's environment. The table prefix, salts, and custom constants are kept. Multisite constants are rewritten by wp-container for the new address.
- **Rewrite rules.** Single sites get WordPress's standard `.htaccess`, because wp-container serves sites with Apache.
- **Add-ons.** Xdebug, Redis, and Elasticsearch are turned on when the LocalWP site uses them. Mailpit is turned on unless `--no-mailpit` is passed.
- **Subdomain networks.** HTTPS is turned on, because wp-container serves a subdomain network's sites as `https://<site>.<domain>` through its HTTPS proxy. Links stored as `http://` are moved to `https://`.
- **Must-use plugins and drop-ins.** wp-container installs WordPress on the site's first start, before the database is imported. `mu-plugins` and `wp-content` drop-ins are set aside for that first start, so code that expects the site's tables can't stop the install, and put back before the import.
- **Symlinks.** Each symlink to a path outside the site is mounted, copied, or skipped:
  - `mount` bind-mounts a linked folder, so edits in it show up in the site straight away. Only folders can be mounted, so a linked file is copied.
  - `copy` copies what the link points to.
  - `skip` leaves the link out of the new site.

  Without `--symlinks`, each link is asked about in turn. Absolute symlinks that point inside the site, such as the `db.php` drop-in Query Monitor creates, become relative links and keep working.

## Limits

- Custom nginx configuration is not carried over. The plan lists any non-stock files in the site's `conf/nginx` folder.
- PHP versions older than 8.1 run on PHP 8.1.
- While LocalWP's router holds ports 80 and 443, requests to the site's domain reach LocalWP, and wp-container's proxy takes ports 8080 and 8443 instead. Free ports 80 and 443, then restart wp-container so its proxy binds them.
- LocalWP sites on MariaDB need `--dump`, because LocalWP ships no MariaDB client binaries.
- While LocalWP is open, its router holds ports 80 and 443, so wp-container's HTTPS addresses reach LocalWP instead. Quit LocalWP to use them.

## If something fails

Any failure after the new site is created deletes that site again, and its folder goes to the Trash. A failed import is also rolled back by wp-container's pre-import backup.

## License

[MIT](LICENSE)
