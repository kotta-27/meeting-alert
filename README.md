# MeetingAlert

A native macOS menu bar app that shows a fullscreen overlay before upcoming calendar events.

## Features

- Fullscreen alert before meetings (configurable lead time: 1/3/5/10 min)
- Detects Google Meet / Zoom / Teams join URLs — click to open directly
- Countdown timer on the overlay
- Snooze (5 min) or dismiss
- Shows today's upcoming events in the menu bar
- Displays last Google Calendar sync time
- Launch at login support

## Requirements

- macOS 14+
- Xcode Command Line Tools: `xcode-select --install`
- Google Calendar connected to macOS Calendar app

## Google Calendar Setup

For the app to pick up calendar changes quickly, set the sync interval to 1 minute:

1. Open **Calendar.app** → Settings (⌘,) → **Accounts**
2. Select your Google account
3. Set **"カレンダーを更新"** (Refresh Calendars) to **Every Minute**

## Install

```bash
# Build
bash build.sh

# Run
open MeetingAlert.app

# Auto-start at login
# → Use the "ログイン時に起動" toggle in the menu bar
```

## Permissions

On first launch, macOS will ask for **Full Calendar Access**. This is required to read event details and join URLs.

## Uninstall

Remove login item via the menu bar toggle, then delete `MeetingAlert.app`.

## License

MIT
