# Omarchy DDEV Backup

🇬🇧 English · 🇮🇹 [Italiano](README.it.md)

A bar plugin for Omarchy 4.x that makes full backups and restores of [DDEV](https://ddev.com) projects: **source code, configuration (`.env`, `.ddev/`) and every database** in a single `.zip` file, in one click.

![DDEV Backup](preview.png)

> The plugin's interface is in Italian.

## Features

- **Full backup** of a project to a `.zip` file: the whole project folder plus a dump of every database in the container (not just `db`). A stopped project is started to export its databases and stopped again afterwards.
- **Database-only backup** with an optional note (for example "before the migration"): fast, meant for right before a risky operation.
- **In-place restore**, exact: files and databases go back to how they were at backup time, and anything created later is removed. A **safety backup** of the current state is always taken before overwriting; if the restore fails, the original folder is put back.
- **Preview before restoring**: date, type, note, databases, git branch and commit (and whether there were uncommitted changes), original folder, machine and DDEV version, size.
- **Restore as a copy**: creates a new DDEV project from a backup, with a name and folder of your choice, without touching the original.
- **Restore from file**: any `.zip` picked with the file chooser, for example copied from another computer. Projects that were deleted from DDEV can also be restored from the list.
- Per project, also **start/stop** (`ddev start` / `ddev stop`) and a **terminal** opened in the project folder.
- **Automatic retention**: keeps the last N full backups and the last M database-only backups per project.
- **Safe operations**: one operation at a time per project, a free disk space check before starting, sha256 verification of the dumps before every restore.
- Supported databases: **MariaDB, MySQL and PostgreSQL**.
- Everything can also be done from a terminal with the `bin/ddev-backup` script, which the panel itself uses.

## Requirements

- Omarchy 4.x with Omarchy Shell (Quickshell).
- [DDEV](https://ddev.com/get-started/) with Docker running.
- `bash`, `jq`, `bsdtar` (libarchive), `unzip` and `notify-send` (libnotify), which ship with Omarchy.

## Installation

```bash
omarchy plugin add https://github.com/zeroviger/omarchy-ddev-backup.git --enable
```

The widget is placed in the right section of the bar. To move it:

```bash
omarchy bar move mcp64.ddev-backup --section left   # or center
```

## Usage

Click the archive icon in the bar. For each DDEV project:

| Button | Action |
|---|---|
| ›  | Show the project's backups |
| >_ | Open a terminal in the project folder |
| ▶ / ■ | Start or stop the project |
| 🛢 | Database-only backup, with an optional note |
| 💾 | Full backup |

For each backup in the list:

| Button | Action |
|---|---|
| ⧉ | Restore as a copy (full backups only): name and folder of the new project |
| ↺ | Restore, after the preview and a confirmation |
| 🗑 | Delete, after a confirmation |

In the panel header: open the backup folder, restore from a `.zip` file, settings, refresh.

Esc first closes the open confirmation or form, then the panel. The panel can also be opened from a terminal or bound to a shortcut:

```bash
qs -p /usr/share/omarchy/shell ipc call mcp64.ddev-backup toggle
```

### From a terminal

```bash
B=~/.config/omarchy/plugins/mcp64.ddev-backup/bin/ddev-backup
$B list                                              # projects and backups (JSON)
$B backup myproject                                  # full backup
$B backup myproject --db-only --label "before the migration"
$B inspect ~/Backups/ddev/myproject/myproject-20261015-102100.zip
$B restore <file.zip> --force                        # overwrite the project
$B restore <file.zip> --to ~/Projects/copy --name copy     # create a copy
$B delete <file.zip>
```

A database-only backup is restored onto the existing project with the same name (or `--name`) and leaves the files alone.

## What a backup contains

```
manifest.json          project, backup type, note, DDEV version, databases, git, sha256 of the dumps
database/<db>.sql.gz   one dump per database
files/                 the whole project folder (full backups only)
```

Files are named `<project>-YYYYMMDD-HHMMSS[-db][-pre-restore][-note].zip` and live in `<backup folder>/<project>/`. They are plain `.zip` files that any archive tool can open.

Left out of backups: files DDEV regenerates by itself (`.ddev/.ddev-docker-compose-*`, `.ddev/db_snapshots`, `.ddev/traefik/certs`, …) and the patterns set in **Exclude** (`node_modules` by default). To leave out more for a single project, create a `.ddev-backup-ignore` file in its folder with one pattern per line.

## How restore works

1. Checks free space, extracts the zip to a temporary folder next to the destination and verifies the sha256 of the dumps.
2. If the project already exists: safety backup (`…-pre-restore.zip`), then `ddev delete` (containers and databases, not files).
3. Swaps the folder, runs `ddev start` and `ddev import-db` for each database.
4. If anything fails, it puts the original folder back and prints the command to recover the database from the safety backup.

With PostgreSQL, open connections to the databases being replaced (application, workers, clients) are closed, since Postgres would otherwise refuse to drop them. Folders left out of the backup, such as `node_modules`, need to be rebuilt after a restore (for example `ddev npm install`).

## Configuration

From the ⚙ gear in the panel. Values are stored in the widget's entry in `~/.config/omarchy/shell.json`, where the terminal script reads them too:

| Key         | Default          | Description |
|-------------|------------------|-------------|
| `backupDir` | `~/Backups/ddev` | Backup folder (one subfolder per project) |
| `keep`      | `10`             | Full backups kept per project (0 = all) |
| `keepDb`    | `20`             | Database-only backups kept per project (0 = all) |
| `exclude`   | `node_modules`   | Patterns left out of backups, comma-separated |
| `notify`    | `true`           | Notification when a backup or restore finishes |

Example:

```json
{ "id": "mcp64.ddev-backup", "backupDir": "/mnt/nas/ddev", "keep": 5, "exclude": "node_modules, vendor" }
```

or from a terminal: `omarchy bar set mcp64.ddev-backup keep 5 --json`.

Safety backups taken before a restore don't count towards the limits and are never deleted automatically.

## Removal

```bash
omarchy plugin remove mcp64.ddev-backup
```

Backups in the backup folder (`~/Backups/ddev` by default) are not deleted.

## Limitations and caveats

- **Backups are not encrypted** and contain `.env`, keys and database data. Archives are created readable only by you (`600`) and the folders the plugin creates are private (`700`), but on drives that ignore Unix permissions (some NAS or FAT/exFAT mounts) this has no effect: keep them somewhere safe.
- Restore is exact: anything created after the backup disappears from the project (it stays in the safety backup).
- The space check covers the backup folder and the project folder, not the Docker storage used while importing databases.
- With PostgreSQL, a restore cuts the application's connections to the database: running workers and processes will have to reconnect.
- Project names may only contain letters, digits and hyphens, as DDEV requires.

## Development and tests

```bash
test/run-tests.sh
```

End-to-end tests (about 8 minutes): they create throwaway DDEV projects under `~/.cache` (one MariaDB, one PostgreSQL), exercise full and database-only backups, restore, copy, rollback, checksums, locking, insufficient space, settings, retention and deletion, then remove everything. Docker and DDEV must be running; `shellcheck` is used if installed.

## License

MIT. See [LICENSE](LICENSE).
