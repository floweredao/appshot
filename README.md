# Appshot

[한국어](README-ko.md)

A macOS menu bar app that sends "what I'm looking at" to a chat assistant, inspired by the Appshots feature in the Codex Mac app.

Press both Command keys together. Appshot then:

1. Captures the frontmost window with ScreenCaptureKit (no shadow, full resolution).
2. Reads the window's text through the Accessibility API, including text that is scrolled out of view when the app exposes it. It also records the app name, window title, and page URL for browsers.
3. Opens a small floating panel. Type one line (optional) and press Return to send, or press Esc to cancel. You can choose where the reply should go: the most recent conversation, or any channel from your config.

Appshot does not talk to Discord or any network service. It hands the capture to a local assistant through files:

```
<inboxDir>/<yyyyMMdd-HHmmss-SSS>/
  shot.png    full-resolution window capture
  shot.jpg    preview, long edge 1568 px
  text.md     window text (Markdown)
  meta.json   app, window, URL, your note, target channel, errors
```

The folder is written in a staging directory and renamed into place. Inside the staging directory, each file is written as `.tmp` and then renamed. After that, one line is appended to the assistant's events log:

```
EVENT APPSHOT <absolute folder path>
```

The assistant watches that log, reads the folder, and replies in `meta.channel.id`.

## Requirements

- macOS 15 or later. On macOS 26 and later the panel uses Liquid Glass.
- Xcode 16 or later, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- An Apple Development certificate. Signing with the same certificate every time keeps the Screen Recording and Accessibility grants across updates.

## Build and install

```sh
echo 'DEVELOPMENT_TEAM = <your team id>' > Config/Local.xcconfig   # git-ignored
./scripts/build.sh --install                                         # -> /Applications/Appshot.app
swift test --package-path Packages/AppshotCore                       # unit tests
```

On first launch Appshot turns on "Open at Login" and opens the settings window. In that window:

- Grant **Screen Recording** (for the screenshot) and **Accessibility** (for window text and the global shortcut), then press **Restart**.
- Create the config file (see below).
- Optionally change the shortcut. You can use both ⌘, both ⌥, both ⇧, both ⌃, or record any key combination.

## Configuration

Machine-specific values never live in the repository. Appshot reads `~/Library/Application Support/Appshot/config.json`:

```json
{
  "stateDir": "~/path/to/assistant/state",
  "inboxDir": "~/path/to/assistant/inbox/appshot",
  "channels": [
    { "key": "general", "label": "#general", "id": "GENERAL_CHANNEL_ID" },
    { "key": "coding",  "label": "#coding",  "id": "CODING_CHANNEL_ID" },
    { "key": "dm",      "label": "DM",       "id": "DM_CHANNEL_ID" }
  ],
  "fallbackChannel": "general",
  "assistantName": "Assistant"
}
```

| Key | Meaning |
| --- | --- |
| `stateDir` | Folder that holds `events.log`, `owner-inbox.jsonl`, and `handled-ids.txt`. Override any of them with `eventsLog`, `ownerInbox`, or `handledIds`; relative paths resolve against `stateDir`. |
| `inboxDir` | Where appshot folders are created. |
| `channels` | Destinations shown in the panel. |
| `fallbackChannel` | Used for "recent" when no conversation history is found. |

The **recent** destination works like this. Appshot takes the last ID in `handled-ids.txt` and looks up that message's `channel` in `owner-inbox.jsonl`, which has one JSON object per line with `id` and `channel`. If that ID isn't found, it uses the last line of `owner-inbox.jsonl`. If neither exists, it uses `fallbackChannel`.

Keep this file and the inbox outside `~/Documents`, `~/Desktop`, and `~/Downloads`. Otherwise macOS asks for folder access on every read.

## Scripting

```sh
open -n -W -a Appshot --stdout out.txt --stderr err.txt --args \
  --appshot-now --note "what is this?" --channel recent [--config /path/config.json] [--delay-ms 500]
```

This captures the frontmost window without showing the panel and writes the folder. It prints the folder path and exits with status 0. Nonzero exit codes mean: 2 config error, 3 no window, 4 unknown channel, 5 write failure. If a permission is missing, the folder is still written and the missing part is listed in `meta.json` under `errors`.

## Privacy

- Password fields (`AXSecureTextField`) are never read.
- Captures stay on your Mac in `inboxDir`. Appshot itself sends nothing over the network.
- `scripts/prepush-check.sh` runs gitleaks and scans tracked files, history, and commit identities for emails, home paths, Discord-style IDs, images, and personal strings listed in a git-ignored patterns file. Install it as a hook with `ln -s ../../scripts/prepush-check.sh .git/hooks/pre-push`.

## License

MIT. See [LICENSE](LICENSE).
