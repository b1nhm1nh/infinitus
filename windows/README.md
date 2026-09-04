# Infinitus on Windows (`infinitus-win`)

Windows daemon and CLI for the [Infinitus](https://github.com/deathemperor/infinitus)
phone companion (`ios/InfinitusMobile`), driving Claude Code instances running
natively on Windows (Windows Terminal + `claude.exe`).

## Why

Claude Code's built-in `--remote-control` is disabled whenever a custom
`ANTHROPIC_BASE_URL` is set (e.g. local swap proxies, corporate gateways, or 9Router).
Infinitus bypasses this limitation by reading Claude Code's local state outside
the engine:
- Session descriptors and credentials: `%USERPROFILE%\.claude\sessions\*.json` and `*.key`
- Transcripts and tool progress: `%USERPROFILE%\.claude\projects\<slug>\*.jsonl`
- Input delivery: Claude Code's local named pipes (`\\.\pipe\LOCAL\cc-msg-<hex>`)

## Prerequisites

- **Windows 10 / 11** (x86_64)
- **Swift Toolchain 6.3+**:
  ```powershell
  winget install --id Swift.Toolchain -e
  ```
- **Windows SDK** (e.g. Windows SDK 10.0.26100, installed via Visual Studio Installer or Windows SDK standalone installer)
- **Optional**: `qrencode` on `PATH` for rendering terminal QR codes during pairing

## Build & Environment

Before building or running `swift`, configure toolchain paths and SDK root in your PowerShell session:

```powershell
. .\windows\env.ps1
```

Build the executable:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\build.ps1
```

Or invoke `swift build` directly:

```powershell
swift build --product infinitus-win
```

Run test suite:

```powershell
swift test --filter InfinitusWinTests
```

Binary location: `.\.build\debug\infinitus-win.exe`.

---

## Subcommands & Real Output

All examples below show verified output from `infinitus-win 0.4.1` on Windows 11.

### Version: `--version` / `-V`

Prints the current version matching the Infinitus release track.

```powershell
.\.build\debug\infinitus-win.exe --version
```
```text
infinitus-win 0.4.1
```

### Sessions: `sessions`

Inspects all Claude Code sessions on this host. Verifies process liveness via
`OpenProcess` and matches process creation `FILETIME` against session records to
prevent stale PID reuse. Probes the named pipe (`\\.\pipe\LOCAL\cc-msg-*`) with
`WaitNamedPipeW` without connecting or sending bytes.

```powershell
.\.build\debug\infinitus-win.exe sessions
```
```json
[
  {
    "alive" : true,
    "cwd" : "D:\\w\\git\\tools-org\\infinitus",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-4c6d4d1d5fa3ebe5312b917ef19769b8",
    "name" : "infinitus-ec",
    "pid" : 1840,
    "pipe" : true,
    "status" : "idle"
  },
  {
    "alive" : true,
    "cwd" : "D:\\ref-app\\app-game-mod",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-c44459752049fd89d08286a068e8e26a",
    "name" : "app-game-mod-0b",
    "pid" : 3116,
    "pipe" : true,
    "status" : "idle"
  },
  {
    "alive" : true,
    "cwd" : "D:\\ref-app\\app-game-mod",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-67d05089c995560e3a84d076ab583125",
    "name" : "app-game-mod-5c",
    "pid" : 9484,
    "pipe" : true,
    "status" : "idle"
  },
  {
    "alive" : true,
    "cwd" : "D:\\w\\git\\beam-org\\beam-mediaplayer",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-d7f25f89b86ad3e6a1c71991eaca622b",
    "name" : "beam-mediaplayer-1b",
    "pid" : 15308,
    "pipe" : true,
    "status" : "idle"
  },
  {
    "alive" : true,
    "cwd" : "D:\\w\\git\\proxmox",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-ff3358d06e81627cb4c605ea625674f9",
    "name" : "proxmox-7f",
    "pid" : 17532,
    "pipe" : true,
    "status" : "idle"
  },
  {
    "alive" : true,
    "cwd" : "D:\\w\\git\\tools-org\\infinitus",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-f26987bb665b0570ab76adde3e9d8338",
    "name" : "infinitus-c9",
    "pid" : 24928,
    "pipe" : true,
    "status" : "busy"
  },
  {
    "alive" : true,
    "cwd" : "D:\\w\\git\\proxmox",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-605c45444ced46a9475d727760e9db37",
    "name" : "proxmox-56",
    "pid" : 34272,
    "pipe" : true,
    "status" : "idle"
  }
]
```

### Pairing: `pair`

Generates and stores a 24-character base32 pairing token, detects non-loopback
IPv4 adapters (LAN, Tailscale), and formats the `infinitus://pair` URL. If `qrencode`
is installed, outputs an ANSI QR code for phone scanning.

```powershell
.\.build\debug\infinitus-win.exe pair
```
```text
infinitus://pair?url=http%3A%2F%2F192.168.6.12%3A47824&url=http%3A%2F%2F100.104.227.59%3A47824&token=2FDPAIJT3S5BSLM4EM6RPTVG
pairing token 2FDP••••••••••••••••PTVG — `infinitus-win pair --show` prints it
install qrencode for a QR
```

To print unmasked token without URL formatting:
```powershell
.\.build\debug\infinitus-win.exe pair --show
```
```text
2FDPAIJT3S5BSLM4EM6RPTVG
```

Supported flags:
- `--show`: Print stored unmasked token
- `--rotate`: Generate and store new pairing token
- `--stdin`: Read token from standard input
- `--token-file <path>`: Read token from file
- `--port <number>`: Override port in generated URLs (default `47824`)

### Snapshot: `snapshot`

Generates the exact JSON payload expected by the phone remote at `GET /snapshot`.
Contains a synthetic fleet descriptor (`claude-code-windows`), session counters,
and parsed per-PID progress (goal, nowDoing, active model, token metrics).

```powershell
.\.build\debug\infinitus-win.exe snapshot
```
```json
{
  "capturedAt" : "2026-09-04T10:34:57Z",
  "fleets" : [
    {
      "accounts" : [

      ],
      "engineID" : "claude-code-windows",
      "liveSessions" : {
        "busy" : 1,
        "idle" : 6,
        "sessions" : [
          {
            "cwd" : "D:\\w\\git\\tools-org\\infinitus",
            "kind" : "interactive",
            "pid" : 1840,
            "startedAt" : 1788508650335,
            "status" : "idle"
          },
          {
            "cwd" : "D:\\ref-app\\app-game-mod",
            "kind" : "interactive",
            "pid" : 3116,
            "startedAt" : 1788504390771,
            "status" : "idle"
          },
          {
            "cwd" : "D:\\ref-app\\app-game-mod",
            "kind" : "interactive",
            "pid" : 9484,
            "startedAt" : 1788495982861,
            "status" : "idle"
          },
          {
            "cwd" : "D:\\w\\git\\beam-org\\beam-mediaplayer",
            "kind" : "interactive",
            "pid" : 15308,
            "startedAt" : 1788495783800,
            "status" : "idle"
          },
          {
            "cwd" : "D:\\w\\git\\proxmox",
            "kind" : "interactive",
            "pid" : 17532,
            "startedAt" : 1788494441754,
            "status" : "idle"
          },
          {
            "cwd" : "D:\\w\\git\\tools-org\\infinitus",
            "kind" : "interactive",
            "pid" : 24928,
            "startedAt" : 1788508350623,
            "status" : "busy"
          },
          {
            "cwd" : "D:\\w\\git\\proxmox",
            "kind" : "interactive",
            "pid" : 34272,
            "startedAt" : 1788495375043,
            "status" : "idle"
          }
        ],
        "shell" : 0,
        "total" : 7,
        "unknown" : 0,
        "waiting" : 0
      },
      "provider" : "claude"
    }
  ],
  "listJSON" : "eyJzY2hlbWFWZXJzaW9uIjoxLCJhY2NvdW50cyI6W10sImxpdmVTZXNzaW9ucyI6eyJ3YWl0aW5nIjowLCJidXN5IjoxLCJ1bmtub3duIjowLCJ0b3RhbCI6NywiaWRsZSI6Niwic2hlbGwiOjAsInNlc3Npb25zIjpbeyJzdGF0dXMiOiJpZGxlIiwia2luZCI6ImludGVyYWN0aXZlIiwic3RhcnRlZEF0IjoxNzg4NTA4NjUwMzM1LCJjd2QiOiJEOlxcd1xcZ2l0XFx0b29scy1vcmdcXGluZmluaXR1cyIsInBpZCI6MTg0MH0seyJjd2QiOiJEOlxccmVmLWFwcFxcYXBwLWdhbWUtbW9kIiwic3RhcnRlZEF0IjoxNzg4NTA0MzkwNzcxLCJwaWQiOjMxMTYsInN0YXR1cyI6ImlkbGUiLCJraW5kIjoiaW50ZXJhY3RpdmUifSx7ImN3ZCI6IkQ6XFxyZWYtYXBwXFxhcHAtZ2FtZS1tb2QiLCJzdGFydGVkQXQiOjE3ODg0OTU5ODI4NjEsImtpbmQiOiJpbnRlcmFjdGl2ZSIsInN0YXR1cyI6ImlkbGUiLCJwaWQiOjk0ODR9LHsiY3dkIjoiRDpcXHdcXGdpdFxcYmVhbS1vcmdcXGJlYW0tbWVkaWFwbGF5ZXIiLCJzdGFydGVkQXQiOjE3ODg0OTU3ODM4MDAsImtpbmQiOiJpbnRlcmFjdGl2ZSIsInN0YXR1cyI6ImlkbGUiLCJwaWQiOjE1MzA4fSx7ImN3ZCI6IkQ6XFx3XFxnaXRcXHByb3htb3giLCJzdGFydGVkQXQiOjE3ODg0OTQ0NDE3NTQsInBpZCI6MTc1MzIsInN0YXR1cyI6ImlkbGUiLCJraW5kIjoiaW50ZXJhY3RpdmUifSx7ImN3ZCI6IkQ6XFx3XFxnaXRcXHRvb2xzLW9yZ1xcaW5maW5pdHVzIiwic3RhcnRlZEF0IjoxNzg4NTA4MzUwNjIzLCJraW5kIjoiaW50ZXJhY3RpdmUiLCJzdGF0dXMiOiJidXN5IiwicGlkIjoyNDkyOH0seyJjd2QiOiJEOlxcd1xcZ2l0XFxwcm94bW94Iiwic3RhcnRlZEF0IjoxNzg4NDk1Mzc1MDQzLCJraW5kIjoiaW50ZXJhY3RpdmUiLCJzdGF0dXMiOiJpZGxlIiwicGlkIjozNDI3Mn1dfX0=",
  "machineName" : "DESKTOP-M4T7IB",
  "progressByPid" : {
    "15308" : {
      "gitBranch" : "main",
      "goal" : "check and add to our ts as new source  \"D:\\w\\git\\ref-spotiflac\\SpotiFLAC-Extension\\extensions\\",
      "lastActivityAt" : "2026-09-04T08:07:24Z",
      "model" : "glm-5.3-flash",
      "name" : "beam-mediaplayer-1b",
      "nowDoing" : "Done — pushed (`4be9fbf`). Full setup:",
      "outputTokens" : 3798,
      "recentOutputTokens" : 0,
      "retrying" : false
    },
    "17532" : {
      "gitBranch" : "HEAD",
      "goal" : "how to create a new proxmox user and grant key access for our AI agent to work with it as root",
      "lastActivityAt" : "2026-09-04T08:43:14Z",
      "model" : "glm-5.3-flash",
      "name" : "proxmox-7f",
      "nowDoing" : "Physical answer — **the card was never installed in hpz2**:",
      "outputTokens" : 60310,
      "phase" : "building",
      "recentOutputTokens" : 0,
      "retrying" : false
    },
    "1840" : {
      "gitBranch" : "windows-remote",
      "goal" : "Another Claude session sent a message:",
      "lastActivityAt" : "2026-09-04T10:21:44Z",
      "model" : "glm-5.3-flash",
      "name" : "infinitus-ec",
      "nowDoing" : "Both sends now delivered (held one released, named one direct). Done.",
      "outputTokens" : 990,
      "recentOutputTokens" : 0,
      "retrying" : false
    },
    "24928" : {
      "gitBranch" : "windows-remote",
      "goal" : "check if we can run and remote control windows with our windows terminal & CC",
      "lastActivityAt" : "2026-09-04T10:33:47Z",
      "model" : "claude-opus-5",
      "name" : "infinitus-c9",
      "nowDoing" : "Status: three Sonnet coders spawned as asked, two alive.",
      "outputTokens" : 57226,
      "phase" : "exploring",
      "recentOutputTokens" : 18211,
      "retrying" : false
    },
    "3116" : {
      "gitBranch" : "HEAD",
      "goal" : "can we find where is claude code installe",
      "lastActivityAt" : "2026-09-04T07:35:33Z",
      "model" : "glm-5.3-flash",
      "name" : "app-game-mod-0b",
      "nowDoing" : "Analysis complete — and it flips my earlier answer. **You already have both.** N",
      "outputTokens" : 45065,
      "phase" : "exploring",
      "recentOutputTokens" : 0,
      "retrying" : false
    },
    "34272" : {
      "gitBranch" : "HEAD",
      "goal" : "how to create a new proxmox user and grant key access for our AI agent to work with it as root",
      "lastActivityAt" : "2026-09-04T08:43:14Z",
      "model" : "glm-5.3-flash",
      "name" : "proxmox-56",
      "nowDoing" : "Physical answer — **the card was never installed in hpz2**:",
      "outputTokens" : 60310,
      "phase" : "building",
      "recentOutputTokens" : 0,
      "retrying" : false
    },
    "9484" : {
      "gitBranch" : "HEAD",
      "goal" : "check  \"D:\\ref-app\\xiaomiwallet\"  we need to find hidden api to change xiaomi nfc to emylate nfc c",
      "lastActivityAt" : "2026-09-04T04:26:18Z",
      "model" : "glm-5.3-flash",
      "name" : "app-game-mod-5c",
      "nowDoing" : "Status:",
      "outputTokens" : 63607,
      "phase" : "exploring",
      "recentOutputTokens" : 0,
      "retrying" : false
    }
  },
  "sessions" : [
    {
      "goal" : "check if we can run and remote control windows with our windows terminal & CC",
      "nowDoing" : "Status: three Sonnet coders spawned as asked, two alive.",
      "phase" : "exploring",
      "repo" : "infinitus",
      "retrying" : false,
      "status" : "busy"
    }
  ]
}
```

Supported flags:
- `--claude-dir <path>`: Override Claude configuration root (defaults to `%USERPROFILE%\.claude`)

### Input Injection: `message`

Injects a cross-session message directly into a running Claude Code session over its
named pipe (`\\.\pipe\LOCAL\cc-msg-*`).

Use `--dry-run` to view the exact wire frames (auth line + user frame) without sending:

```powershell
.\.build\debug\infinitus-win.exe message --pid 1840 --dry-run "hello from cli"
```
```text
{"token":"e80c951659f38d5e0cdfa3165c009032","type":"auth"}
{"from":"uds:\\\\.\\pipe\\LOCAL\\infinitus-29616","message":{"content":"<cross-session-message from=\"uds:\\\\.\\pipe\\LOCAL\\infinitus-29616\" from-name=\"Infinitus app\" from-mode=\"bypass\">\nhello from cli\n<\/cross-session-message>","role":"user"},"msg_id":"49a52a9c-5483-4881-be21-b74033f8b149","msgV":1,"priority":"next","type":"user"}
```

Live delivery:

```powershell
.\.build\debug\infinitus-win.exe message --pid 1840 "hello from cli"
```
```text
delivered to 1840 (infinitus-ec)
```

Supported flags:
- `--pid <number>`: Target session process ID (required)
- `--dry-run`: Format and print NDJSON wire frames without connecting
- `--claude-dir <path>`: Override Claude configuration root

---

## Pairing Security & Storage

The pairing token is stored at:
```text
%APPDATA%\Infinitus\pair-token
```

Security configuration:
- The token file is protected with a user-only Discretionary Access Control List (DACL)
- Only `SYSTEM`, `Administrators`, and the current user SID have full control access
- Inheritance is disabled (`PROTECTED_DACL_SECURITY_INFORMATION`)

---

## Firewall Note

To allow incoming connections from the Infinitus phone client on your local Wi-Fi,
allow inbound traffic on TCP port `47824` on the Private network profile:

```powershell
netsh advfirewall firewall add rule name="Infinitus" dir=in action=allow protocol=TCP localport=47824
```

---

## `serve` — the phone's HTTP surface

`infinitus-win serve [--port N] [--claude-dir P] [--token-file P]` runs the
server the phone talks to. Without `--token-file` it uses the stored pairing
token, so `pair` then `serve` is the whole setup.

```
> infinitus-win serve
listening on 47824
  http://192.168.6.12:47824
  http://100.104.227.59:47824
token 2FDP••••••••••••••••PTVG — `infinitus-win pair` prints the pairing URL
if the phone can't reach it, allow inbound TCP 47824:
  netsh advfirewall firewall add rule name="Infinitus 47824" dir=in action=allow protocol=TCP localport=47824
```

Routes (all require `Authorization: Bearer <token>`, or `?t=<token>`):

| route | answers |
|---|---|
| `GET /snapshot` | the fleet + session snapshot, 5 s cache |
| `GET /sessions/<pid>/tail?n=&since=&wait=` | the session's feed; holds up to 25 s when `since` matches the current stamp |
| `GET /sessions/<pid>/images/<id>` | a feed image, original bytes, 5 MiB cap |
| `POST /sessions/<pid>/input` | `message`, `resume` or `key`; delivery over the named pipe |
| `POST /activities/token` | accepted and discarded (no APNs on Windows) |

Verified on this box (2026-09-04): 401 without a token, 200 with; snapshot
listing 7 live sessions; a tail carrying real items with `canMessage=true`,
`keys=false`, `permissionMode=bypassPermissions`; long-poll returning in 8 ms
on a stale stamp and holding 4.1 s on a current one; a `message` answering
`{"channel":"socket","outcome":"delivered"}` and appearing in the target
session's transcript; a `key` answering `{"outcome":"noSurface"}`.

**Held for approval.** When the sending and receiving sessions' permission
modes differ in class, Claude Code holds the message for its user to approve
rather than delivering it straight to the model. The daemon reports the write
that succeeded; the phone shows `permissionMode` so it can say so.

---

## Not Yet Implemented

The following features from the Windows architecture plan (`docs/plan-windows/`)
are pending and **not yet present in `main.swift` today**:

1. **Bonjour Advertising**:
   Zero-configuration service advertisement (`_infinitus._tcp.local:47824`) via `DnsServiceRegister`. Until then the phone needs the host typed in manually (`pair` prints the addresses).
2. **WIC Thumbnails**:
   Image downscaling to ≤ 640px JPEG using Windows Imaging Component (`IWICImagingFactory`). The image route serves original bytes today.
3. **Phone-side multi-host UI**:
   The storage and transport layer ships (`MirrorHost`, per-host tokens); the merged sessions list, per-host sections and Settings UI are still to come.
4. **Automatic Resume / Nudge Daemon**:
   Automated background detection of limit-stopped sessions and quota release triggers. `infinitus-win resume` does it manually; the automatic quota monitor is macOS-only because this box runs no swap engine to ask.
