# ClipWatch

A fast, keyboard-driven clipboard history manager for macOS. Lives in the menu bar. Zero dependencies. Built to last.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green) ![Version](https://img.shields.io/badge/version-1.3.0-lightgrey)

## What it does

ClipWatch silently records everything you copy as plain text. When you need something from your clipboard history, one shortcut opens a searchable panel — type to filter across your full history, arrow to the item you want, hit Enter. It pastes immediately.

Pinned items always float to the top. Passwords from 1Password and other credential managers are silently excluded. Sensitive clips (credentials, API tokens, credit cards) are auto-detected and locked behind Touch ID until you choose to reveal them.

---

## Install — step by step (no technical experience needed)

**What you need:** A Mac running macOS Ventura (13) or later. That's it.

### Step 1 — Open Terminal

Press **⌘ Space** to open Spotlight, type `Terminal`, and press **Enter**. A black-and-white window will open. That's normal.

### Step 2 — Install developer tools (one-time, takes ~2 minutes)

Paste this into Terminal and press **Enter**:

```
xcode-select --install
```

A dialog will pop up. Click **Install**, then **Agree**. Wait for it to finish. If it says "already installed", skip to Step 3.

### Step 3 — Download ClipWatch

Paste this into Terminal and press **Enter**:

```
git clone https://github.com/lswingrover/clipwatch && cd clipwatch
```

### Step 4 — Install

Paste this and press **Enter**:

```
./build_app.sh
```

Wait about 30 seconds. When you see `ClipWatch installed ✅`, you're done.

### Step 5 — Grant permission

ClipWatch will appear in your menu bar (look for a small clipboard icon **📋** near the clock). The first time you use the keyboard shortcut, macOS will ask for **Accessibility** access — click **Open System Settings**, then flip the toggle next to ClipWatch to on.

That's it. ClipWatch is running.

---

## Using ClipWatch

Press **⌥⌘V** (hold Option + Command, tap V) to open your clipboard history. A search panel appears.

| What you want to do | How |
|---|---|
| Open the panel | `⌥⌘V` (configurable in Preferences) |
| Move up / down the list | `↑` `↓` arrow keys |
| Paste the selected item | `↩` Enter |
| Search your history | Just start typing |
| Pin an item to the top | `⌘P` |
| Mark / unmark as sensitive | `⌘S` |
| Delete an item | `⌘⌫` |
| Close without pasting | `Esc` or press the hotkey again |
| Paste from the menu bar | Click the clipboard icon → click any item |
| Clear all history | Menu bar icon → **Clear History…** |

---

## Sensitive clips (privacy protection)

ClipWatch automatically detects when you copy something sensitive — API keys, passwords, credit card numbers, tokens, private keys — and marks those clips as **locked**. Locked clips show a placeholder in the panel instead of the real content.

To paste a locked clip, press Enter — Touch ID (or your login password) will unlock it for the session.

You can manually lock or unlock any clip with **⌘S**. How long ClipWatch stays unlocked after one authentication is configurable in **Preferences → Security → Stay unlocked for**.

---

## Preferences

Open via the menu bar icon → **Preferences…** (or `⌘,` when the panel is open).

**Hotkey** — click the field and press your preferred shortcut.

**Menu** — how many recent clips to show in the menu bar dropdown (5–25, default 10).

**History** — how many days to keep clipboard history (30–730 days, default 365).

**Panel appears on** — open the panel on the screen where your active app is, or where your cursor is.

**Launch at login** — start ClipWatch automatically when you log in.

**Security**
- *Require Touch ID to open panel* — lock the entire panel behind Touch ID; no clips are visible until you authenticate.
- *Stay unlocked for* — after one authentication, how long before Touch ID is required again: every use, 5 min, 15 min, 30 min, 1 hour, or until the app restarts.

**Data** — *Clear All History…* permanently deletes your entire clipboard history. Cannot be undone.

**Never capture from** — apps and websites that ClipWatch ignores entirely. Pre-seeded with 1Password, Bitwarden, and LastPass. Drag any `.app` onto the list, click `+` to browse, or add a URL/domain pattern.

---

## Updates

ClipWatch checks GitHub for new releases each time it launches. If a newer version is available, a **"⬆ Update available: vX.X.X"** item appears at the top of the menu bar dropdown. Click it to go to the release page.

To update manually, just run the same commands from Step 3 and 4 again inside your existing `clipwatch` folder:

```bash
cd ~/clipwatch          # or wherever you put it
git pull
./build_app.sh
```

---

## Privacy

ClipWatch runs entirely on your Mac. Nothing is sent anywhere. The clipboard database is a local SQLite file at:

```
~/Library/Application Support/ClipWatch/clips.db
```

Apps in the exclusion list are filtered at insert time — their clipboard contents never touch the database. Sensitive clips are stored encrypted by the OS filesystem; the raw content is only revealed after Touch ID or password authentication.

Time Machine backs the database up automatically as part of your normal Mac backup.

---

## Building from source

Requirements: macOS 13+, Xcode Command Line Tools.

```bash
# Debug build + install (default)
./build_app.sh

# Release build (optimized)
./build_app.sh --release

# Build only, don't install
swift build

# Run tests
swift test
```

---

## Architecture

```
Sources/ClipWatch/
  main.swift                        Entry point — NSApplication setup
  AppDelegate.swift                 Status item, menu bar, paste via CGEvent
  ClipStore.swift                   SQLite (FTS5 search, sensitive column)
  ClipboardMonitor.swift            NSPasteboard polling (0.5 s), URL exclusion
  HotkeyManager.swift               NSEvent global monitor, Accessibility check
  PanelController.swift             Floating NSPanel, Touch ID gate, unlock window
  SearchViewController.swift        Search field + table + ClipCellView
  PreferencesWindowController.swift All user settings + ShortcutRecorderField
  Prefs.swift                       UserDefaults keys and defaults
  SensitiveDetector.swift           Regex credential detection (11 pattern classes)
  UpdateChecker.swift               GitHub release comparison, update banner
```

The clipboard monitor polls `NSPasteboard.general.changeCount` every 500 ms. There is no push API for clipboard changes on macOS — polling is the standard approach used by every clipboard manager on the platform.

Paste is simulated by posting a `CGEvent` for `⌘V` after placing the selected text on `NSPasteboard.general`. A short delay ensures the previous app has regained focus before the keystroke fires.

---

## License

MIT. See [LICENSE](LICENSE).

---

Part of the [*Watch suite](https://github.com/lswingrover): MacWatch · NetWatch · NarWatch · VolleyWatch · ClipWatch.
