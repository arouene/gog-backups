# gog-backups
Back up a GOG library from Emacs

Requires Emacs 28.1 or later and [acurl](https://github.com/arouene/acurl)
on the `load-path`. See the commentary of `gog-backups.el` for usage.

## Development

```sh
make ACURL_DIR=path/to/acurl   # byte-compile, checkdoc, tests
```

Tests need `curl` and `python3`: integration tests start `test/server.py`, a
local stand-in for the GOG endpoints. CI fetches the private acurl repository
with the `ACURL_TOKEN` secret, a read-only token for `arouene/acurl`.
