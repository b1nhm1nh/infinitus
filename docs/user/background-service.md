# Running the server in the background

A Linux machine can run the Infinitus server as a service for your user, so it
stays available to your phone, a browser or the desktop app without a terminal
kept open.

## Before you start

The service runs the self-contained server from a release archive. Get it onto
the machine first:

```sh
curl -fsSL https://infinitus.run/install.sh | sh
```

It downloads the newest release's `t3-<version>-linux-<arch>.tar.gz`, checks
it against the release's `SHA256SUMS`, unpacks it under `~/.infinitus/runtime`
and links `t3` into `~/.local/bin`. It needs only `sh`, `tar`, `curl` or
`wget`, and `sha256sum`; no Node.js. Set `T3CODE_VERSION` to pin a release
(the archives start with the release after 0.5.0-alpha.11), or
`T3CODE_RELEASE_BASE_URL` to download from a mirror.

Without the script, download the archive and `SHA256SUMS` from a
[release](https://github.com/deathemperor/infinitus/releases) yourself, check
it — `sha256sum -c --ignore-missing SHA256SUMS` — and unpack it; the `t3`
inside is the server, run as `./t3` below.

If the machine is an SSH remote of your desktop app, skip all of this: the
desktop puts the matching server on it by itself.

## Manage the service

<<<<<<< HEAD
Run these on the machine that will host the server:
=======
Install the `t3` CLI first ([Install T3 Code](./install.md#command-line)), then
run these commands on the machine that will host T3 Code:
>>>>>>> upstream/main

| Task                            | Command                |
| ------------------------------- | ---------------------- |
| Install and start               | `t3 service install`   |
| Inspect status and log location | `t3 service status`    |
<<<<<<< HEAD
| Update or repair                | `t3 service update`    |
| Stop and remove from startup    | `t3 service uninstall` |

The service reuses the copy the install script put under
`~/.infinitus/runtime`; a hand-unpacked `./t3` downloads that version's
archive there first, so the machine needs to reach the releases (or
`T3CODE_RELEASE_BASE_URL`). Uninstalling the service leaves your projects,
threads and settings under `~/.infinitus/userdata` intact.

`t3 update` moves a script-installed `t3` to the newest release: it downloads
and verifies it, points `t3` at it, and asks before restarting a background
service (pass `--yes` from a script; decline and the service keeps running its
current version until `t3 service restart`; a server you started by hand is
left for you to restart). Pass an exact version to pin one, or `--allow-downgrade` to
move backwards. Install and update use the version of the `t3` you run; an
older `t3` refuses to replace a newer service unless you add
`--allow-downgrade`. `t3 uninstall` reverses the install script — the service,
the `t3` link, every downloaded version — and keeps `~/.infinitus/userdata`.

Updating restarts the server. Finish active work first, and wait for any remote
update already in progress.
=======
| Move to a newer release         | `t3 update`            |
| Restart                         | `t3 service restart`   |
| Stop and remove from startup    | `t3 service uninstall` |

Uninstalling the service leaves your projects, threads, and settings intact.
Running `t3 service install` again repairs a service that `t3 service status`
reports as broken.

`t3 update` downloads the newest release on your channel and switches `t3`
and the service to it. Restarting interrupts running agent turns, terminals,
and remote clients, so it asks first; answer no and the service keeps running
the old version until you run `t3 service restart`. Pass `--yes` from a
script. A server you started by hand is left running; stop and start it again
to pick up the new version. Wait for any remote update already in progress
before updating; to match a remote client's version, follow
[Updating T3 Code](./updating.md).

Pass an exact version (`t3 update 0.0.42`) to pin one, `--channel nightly` to
switch trains, or `--allow-downgrade` to move backwards. `preview` is a
maintainers' test train: its builds can be broken and are never offered as
updates, so the installer and `t3 update` ask for confirmation before
installing one.

`t3 uninstall` removes the background service, the `t3` launcher, and the
downloaded versions after showing you the list and asking once. Your projects,
threads, and settings under `~/.t3/userdata` are kept. Pass `--yes` from a
script.
>>>>>>> upstream/main

## Platform support

Linux needs systemd user services. Setup enables lingering so the server starts
at boot and keeps running after logout. If this needs administrator permission,
setup prints a recovery command before changing the service.

macOS: the service commands exist, but no macOS server archive is published
yet (the install script says so and stops), so there is nothing to install
them from. Keep the desktop app running on
the Mac instead; it hosts remote clients the same way.

Windows background services are not supported.

Infinitus Connect can offer service installation during setup, but the two are managed
separately. Signing out of Infinitus Connect does not stop or uninstall the service.

## Troubleshooting

Start with `t3 service status` on the host. It prints the log path and checks
whether the installed service is running, enabled, and allowed to survive
logout.

If it stops when your SSH session closes, check for `linger-disabled`. An
administrator can enable lingering with:

```sh
sudo loginctl enable-linger "$(id -un)"
```

Over SSH, allow sudo to prompt:

```sh
ssh -t your-server 'sudo loginctl enable-linger "$(id -un)"'
```

Then retry service setup as your normal user. Run only the `loginctl` command
with sudo; running the server as root creates a separate installation and
Connect identity. Without administrator access, run `./t3 serve` in a terminal
and keep that session open.

| Status problem                          | Next step                                                                                                                      |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `linger-unavailable`                    | Run `loginctl show-user "$(id -un)" --property=Linger` and check that systemd-logind is available.                             |
| `user-manager-unavailable`              | Run `systemctl --user status` in a login session for the service user; check your distribution's systemd user-session support. |
| `service-disabled` or `service-stopped` | Read the log and `systemctl --user status t3code.service`, then use the repair command printed by the server.                  |
| `restart-pending`                       | A newer version is installed but the service still runs the previous one. Run `t3 service restart`.                            |

<<<<<<< HEAD
For failures after signing in to Infinitus Connect, see
[connection troubleshooting](./remote-access.md#infinitus-connect-troubleshooting).
=======
On macOS, check **System Settings → General → Login Items** if the service no
longer starts at login. If agent work cannot access Desktop, Documents, or
Downloads, it may need Full Disk Access for the `t3` executable listed in
`ProgramArguments` in
`~/Library/LaunchAgents/com.t3tools.t3code.service.plist`.

For failures after signing in to T3 Connect, see
[connection troubleshooting](./remote-access.md#t3-connect-troubleshooting).
>>>>>>> upstream/main
