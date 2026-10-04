# gog-backups
Back up a GOG library from Emacs

gog-backups lists the games of a GOG account, lets you choose the OS and
languages per game, and downloads the standalone installers and extras into a
directory tree. Backups are incremental and the state is persisted in an ELD
file. All network requests run asynchronously through
[acurl](https://github.com/arouene/acurl): Emacs is never blocked, transient
failures (such as HTTP 503) are retried with backoff and `Retry-After`, and
downloads resume where they stopped.

## Installation

Requires Emacs 28.1 or later, curl 7.75 or later and acurl.

With Emacs 29 or later:

```elisp
(package-vc-install "https://github.com/arouene/acurl")
(package-vc-install "https://github.com/arouene/gog-backups")
```

Or clone both repositories and add them to the `load-path`:

```elisp
(add-to-list 'load-path "~/src/acurl")
(add-to-list 'load-path "~/src/gog-backups")
(autoload 'gog-backups "gog-backups" nil t)
```

## Login

gog-backups logs in like the GOG Galaxy client, with GOG's OAuth
authorization-code flow; no HTML page is parsed.

1. `M-x gog-backups-login` (or any command that needs a token) opens the GOG
   login page in your browser with `browse-url`. The login URL is also copied
   to the kill ring and written to `*GOG Backups Log*`, to open it by hand
   when no browser can be started (for instance in a terminal Emacs).
2. Log in on GOG's site, including the two-factor step if your account has
   one.
3. GOG redirects to a blank page on `embed.gog.com/on_login_success`. Copy its
   URL from the address bar and paste it at the Emacs prompt. The bare value
   of its `code` parameter is accepted too.

gog-backups exchanges the code for an access token and a refresh token, saves
them in `gog-backups-data-file`, and refreshes the access token automatically
when it expires in less than 5 minutes. Your password never goes through
Emacs. Log in again (`M-x gog-backups-login`) only when the refresh token
is rejected ("Token refresh failed, log in again").

The data file holds the tokens: keep it private.

## Usage

`M-x gog-backups` opens the `*GOG Backups*` buffer and fetches the library the
first time.

| Column         | Content                                             |
|----------------|-----------------------------------------------------|
| Mark           | `*` when the game is marked for backup              |
| Title          | Game title                                          |
| State          | `NEW` (not backed up), `OK` (up to date), `UPDATE`  |
| Backup version | Installer version of the last backup                |
| Online version | Installer version currently on GOG                  |
| OS             | OS backed up for this game                          |
| Lang           | Languages backed up for this game                   |
| Size           | Total size of the installers and extras             |

| Key     | Action                                       |
|---------|----------------------------------------------|
| `g` `u` | Refresh the library from GOG                 |
| `m`     | Mark or unmark the game at point             |
| `o`     | Choose the OS of the game at point           |
| `l`     | Choose the languages of the game at point    |
| `B`     | Back up the marked games                     |
| `RET`   | Open the backup directory of the game        |
| `/ n`   | Filter by name                               |
| `/ s`   | Filter by state (`NEW`, `OK`, `UPDATE`)      |
| `/ o`   | Filter by OS                                 |
| `/ l`   | Filter by language                           |
| `/ /`   | Clear the filter                             |
| `q`     | Quit                                         |

Progress shows in the header line and the frame title, and is logged to the
`*GOG Backups Log*` buffer. Only one operation (refresh, backup, login) runs
at a time.

Commands:

| Command               | Action                          |
|-----------------------|---------------------------------|
| `gog-backups`         | Open the list buffer            |
| `gog-backups-login`   | Log in again and save the token |
| `gog-backups-refresh` | Sync the library again          |
| `gog-backups-run`     | Back up the marked games        |

## Backups

Files go to `<gog-backups-backup-dir>/<Game title>/`, named after the real GOG
file name (from `Content-Disposition` or the final CDN URL). Only standalone
installers and extras are downloaded, including the extras of owned DLCs;
patches and hotfixes are skipped.

Each file is downloaded into a `.gog-staging/` subdirectory, checked (see
`gog-backups-verify-md5` and `gog-backups-verify-zip`), and only then
replaces an existing file of the same name, so a failed check never loses a
good backup. A file already present with the expected size is not downloaded
again, and a game whose backup version matches the online version is skipped.

## Customization

`M-x customize-group RET gog-backups`:

| Option                        | Default                    | Meaning                                       |
|-------------------------------|----------------------------|-----------------------------------------------|
| `gog-backups-backup-dir`      | `~/Gog backups`            | Root directory, one subdirectory per game     |
| `gog-backups-data-file`       | `gog-backups.eld` in `user-emacs-directory` | Tokens, games, versions, preferences |
| `gog-backups-os-list`         | `(windows)`                | OS backed up for new games                    |
| `gog-backups-lang-list`       | `("fr")` with a French language environment, else `("en")` | Languages backed up for new games |
| `gog-backups-verify-md5`      | `t`                        | Check the MD5 when GOG provides it            |
| `gog-backups-verify-zip`      | `nil`                      | Check the signature of `.zip` files           |
| `gog-backups-retry-count`     | `4`                        | Attempts per request on transient errors      |
| `gog-backups-request-timeout` | `30`                       | Seconds before a stalled request is abandoned |

Hooks:

| Hook                                    | Run                                         |
|-----------------------------------------|---------------------------------------------|
| `gog-backups-after-fetch-library-hook`  | After the library is fetched                |
| `gog-backups-before-backup-hook`        | Before each game backup, with the game      |
| `gog-backups-after-backup-hook`         | After each game backup, with the game       |
| `gog-backups-all-backups-done-hook`     | After all the marked games are backed up    |

Faces: `gog-backups-update-face` (inherits `warning`), `gog-backups-ok-face`
(`success`), `gog-backups-new-face` (`default`).

## Development

```sh
make ACURL_DIR=path/to/acurl   # byte-compile, checkdoc, tests
```

Tests need `curl` and `python3`: integration tests start `test/server.py`, a
local stand-in for the GOG endpoints.
