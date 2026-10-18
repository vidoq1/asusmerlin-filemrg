# File Manager for Asuswrt-Merlin

A small file manager that lives inside the Asuswrt-Merlin admin interface. It lets you browse `/jffs` and the USB drives plugged into your router, download files, and delete files, all from a regular tab in the WebUI. It does not run a separate web server, does not open extra ports, and does not use the router's SMB/FTP services.

> **Status:** works on an ASUS ROG Rapture GT-AX11000 Pro running Asuswrt-Merlin 3006.102.9. Other models and firmware versions are untested. See [Compatibility](#compatibility).

## Why this exists

Asuswrt-Merlin has no built-in way to look at the files on a USB drive or in `/jffs` from the browser. The usual options all have a cost:

- **SSH/SCP** works, but it means opening a terminal for a quick look or a single file.
- **SMB/FTP sharing** exposes the drive to the whole LAN and needs separate credentials.

This add-on uses what the firmware already provides: the admin login, the WebUI page mechanism (Addons API), and the `service-event` hook. If you can log in to the router, you get the file manager as one more tab. Nothing listens on a new port, and nothing runs permanently in the background.

## Features

- Browse `/jffs` and every USB partition currently mounted under `/tmp/mnt`.
- Storage is detected from `/proc/mounts` at request time. Mount names do not matter (`sda1`, `router`, `usbdrive`, anything). A drive that is not mounted does not appear.
- The storage list updates on boot and on the firmware's `post-mount` and `unmount` events.
- Navigate folders with breadcrumbs.
- Shows name, size, and modification date and time for files and folders.
- Download files up to 50 MiB.
- Delete regular files, with a confirmation that shows the full path.
- Plain English UI with native Asus buttons and the standard WebUI look.
- Clean `install` / `status` / `uninstall` lifecycle. Reinstalling is safe and repeatable.

## What it does not do

- **No upload.** The firmware's built-in add-on channel has no safe way to receive file contents, so this version is read and delete only.
- No rename, move, copy, create folder, or edit.
- No folder download or ZIP.
- No downloads over 50 MiB.
- Symbolic links are not listed and never followed.
- Folders cannot be deleted.
- Listings are capped at 1000 entries per folder.
- No permission levels. Anyone who can log in to the router admin can browse and download everything under `/jffs` and the mounted drives, and delete the files that are not protected (see [Security model](#security-model)).

## How it works
Browser (WebUI tab)
| POST /start_apply.htm (admin session cookie)
| action_script = restart_filemgr, request stored in custom_settings.txt
v
httpd -> service-event hook -> handler.sh (one short-lived shell process)
| |
| +-- validates the request, performs it
| +-- writes a small JSON result file
v
GET /user/filemgr/res-<id>.json (static file served by the firmware's httpd)

1. The page (`userN.asp`) sends a command through the same mechanism that other Merlin add-ons use: the request is written to `/jffs/addons/custom_settings.txt` under `_filemgr_*` keys and the `restart_filemgr` service event fires.
2. `service-event` starts `handler.sh`. It reads and clears the request, validates every field, performs the operation, and writes the result to `/tmp/filemgr-web/` (RAM).
3. The page polls the result file, which the firmware's own `httpd` serves behind the normal admin login.

**Opening the page sends no command.** It only reads `volumes.json`, which is refreshed by boot, `post-mount` and `unmount`. Commands are sent only when you click Refresh, open a folder, download, or delete.

### Downloads

Binary data cannot go through the settings channel, so a download works like this:

1. The router encodes the file as Base64 inside a JSON file in `/tmp/filemgr-web/`. That is RAM, so no flash wear.
2. It creates a random download ID and a random one-time token. Only a hash of the token is stored, in a private directory.
3. The browser fetches the JSON through the authenticated `httpd`, rebuilds the exact bytes, checks the size, and saves the file.
4. The browser then sends a cleanup command with the ID and token. The router deletes only that download's files.
5. If the cleanup never arrives, a one-shot timer removes the files after 5 minutes. There is no cron job and no periodic sweep. Stale records are also purged on the next request.

At most 2 prepared downloads can exist at the same time. Base64 expands the data by about a third, so a 50 MiB file occupies roughly 67 MB of RAM while it is prepared.

### Menu and page slot

- The add-on picks the highest free `userN.asp` slot (`user9` down to `user1`). A slot counts as taken if the file exists **or** if the menu tree still references it, so it does not take over a slot that another add-on has reserved but not yet mounted.
- It reuses its own slot on later runs.
- The tab is added to the Administration menu next to "Restore/Save/Upload Setting". If that entry is missing, it falls back to other standard Administration or LAN entries.
- The page refreshes the WebUI menu cache with a cache-busting query on `menuTree.js`, so the tab shows up without clearing the browser cache.

## Security model

- Access control is the router's admin login. The result and download files are served by the firmware `httpd`, so they require an authenticated session. Without a session the request is redirected to the login page.
- Paths from the browser are hex-encoded and validated on the router: no `..`, no empty or absolute segments, no control characters. Every path component is checked, and any symlink is rejected.
- A storage is identified by an ID derived from its mount path and is resolved from `/proc/mounts` on every request. The browser cannot name an arbitrary directory.
- Cleanup acts only on the download record whose ID and token match. It cannot target any other file or directory, and it never uses recursive deletion.
- Delete only works on regular files. These are protected and cannot be deleted from the UI: everything under `/jffs/scripts/`, `/jffs/addons/filemgr/`, and `/jffs/addons/custom_settings.txt`. They can still be downloaded.
- Not covered: a race where someone with write access to the drive replaces a directory with a symlink between the check and the operation. On a home USB drive this is unlikely, but it is not excluded.

Back up anything you cannot lose before deleting files from `/jffs` or a drive.

## Requirements

- An ASUS router running Asuswrt-Merlin with Addons API support.
- **Administration -> System -> Enable JFFS custom scripts and configs = Yes**
- SSH access to the router to run the installer.
- A browser with `fetch`, `async/await`, and `TextEncoder` (any current Chrome, Firefox, Safari, or Edge).
- For downloads only: a `base64` tool. The installer uses `/opt/bin/base64` (Entware `coreutils-base64`) if present, or the BusyBox applet if the build includes it. Browsing and deleting work without it.

## Compatibility

| Item | Status |
|---|---|
| GT-AX11000 Pro, Merlin 3006.102.9 | Tested |
| Other Merlin 3006.x builds | Should work, untested |
| prev Merlin builds | Untested |
| Stock ASUS firmware | Not supported (no Addons API) |

The modification time column adapts to the BusyBox `ls` output format. If the router's `ls` cannot print full timestamps, files older than about six months show a date without a time.

## Installation

Copy the installer to the router and run it. Use your own admin user and router address:

```sh
scp filemgr-install.sh admin@router_ip:/tmp/
ssh admin@router_ip 'sh /tmp/filemgr-install.sh install'
```

Then hard-refresh the WebUI (Ctrl+Shift+R / Cmd+Shift+R) and open **Administration -> File Manager**.

Check the state at any time:

```sh
sh /jffs/addons/filemgr/install.sh status
```

Running `install` again is safe. It repairs the files and the hook blocks, keeps the page slot, and does not duplicate anything. To update, run the new `filemgr-install.sh install` over the old version.

### What the installer changes

- Creates `/jffs/addons/filemgr/` with the scripts, the page source, a copy of the installer, and timestamped backups of every hook file it edits.
- Appends one marked block (`# BEGIN FILEMGR WEBUI` ... `# END FILEMGR WEBUI`) to `/jffs/scripts/services-start`, `service-event`, `service-event-end`, `post-mount`, and `unmount`. Existing content and other add-ons' blocks are left alone, and a hook file is created only if it does not exist.
- At runtime: copies the page to `/www/user/userN.asp`, links `/www/user/filemgr` to `/tmp/filemgr-web`, and adds one line to `/tmp/menuTree.js`, which is bind-mounted over the firmware menu file.

It does not modify any other add-on's files, does not use `helper.sh`, and does not touch network, firewall, DNS, or Wi-Fi settings.

### Uninstall

```sh
sh /jffs/addons/filemgr/install.sh uninstall
```

This removes only what the add-on added: its hook blocks, page, menu entry, resource link, runtime directories, `_filemgr_*` settings keys, and `/jffs/addons/filemgr/`. Hook files that the installer created and that are now empty are deleted. Files and hooks belonging to other add-ons stay as they were.

## Troubleshooting

| Symptom | Check |
|---|---|
| No tab after install | Hard-refresh the WebUI. Run `install.sh status`. Run `logread \| grep filemgr`. |
| Tab missing after a reboot or an httpd restart | The boot hook waits for the WebUI menu file. Check `/tmp/filemgr-mount.log`. |
| "Storage list is not published yet" | Click Refresh. Then check `/tmp/filemgr-handler.log` and `/tmp/filemgr-publish.log`. |
| Drive not listed | Make sure it is mounted under `/tmp/mnt` (`grep /tmp/mnt /proc/mounts`), then click Refresh. |
| Download fails with "no base64 tool" | Install Entware `coreutils-base64`. |
| Download fails with "larger than the 50 MiB limit" | The limit is intentional. Use SCP for larger files. |
| Request seems to hang | The page waits up to 120 seconds for a result. An expired admin session also looks like a timeout, so log in again. |

Useful logs: `/tmp/filemgr-handler.log`, `/tmp/filemgr-mount.log`, `/tmp/filemgr-publish.log`, and `logread | grep filemgr`.

## Notes and limitations

- Every command is written through the firmware's settings channel, so each click writes a small change to `custom_settings.txt` on JFFS. Opening the page writes nothing. This is the same channel other Merlin add-ons use, but heavy browsing means more small flash writes.
- If the page is opened through a reverse proxy, the cache-busting on the menu file is what keeps the tab visible. Proxies that cache aggressively may still need a cache purge.

## Disclaimer

This software is provided as is, without warranty. It edits shared hook files and can delete files from your router and USB drives. Test on a non-critical setup first and keep backups. The installer saves a backup of every hook file it changes under `/jffs/addons/filemgr/`.

## License

This project is released under the [MIT License](LICENSE.md).

You are free to use, fork, modify, and redistribute it, including for
commercial purposes, provided that you retain the copyright notice
and license text.

Copyright (c) 2026 Albert Sayapov.

## Support the development

Feel free to support the development of this and future builds via [paypal](https://www.paypal.com/donate/?business=D7YMVYBKM8BZW&no_recurring=0&item_name=Support+the+development+github.com%2Fvidoq1&currency_code=USD)
