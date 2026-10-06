# Mug

A dead simple macOS menu bar app that keeps your Mac awake.

- Pick **Indefinitely**, 5, 10, 15, 30 minutes, 1 hour or 2 hours from the menu.
- **During Work Hours** keeps the Mac awake on weekdays between 9 AM and 5 PM (change the times
  with **Set Work Hours…**) and goes back to empty outside them. It's remembered across launches.
- The menu bar mug steams while it's keeping the Mac awake, and sits empty when it's not.
- **Also Move Mouse** (optional) nudges the cursor 1pt and back after each idle minute, so chat apps
  don't mark you away. Needs Accessibility permission (System Settings → Privacy & Security →
  Accessibility); macOS asks the first time you turn it on.
- **Turn Off** (or quitting) lets the Mac sleep normally again.

Under the hood it holds an IOKit `PreventUserIdleDisplaySleep` assertion — check it with
`pmset -g assertions`.

## Build

Requires macOS 13+ and the Swift toolchain (Command Line Tools is enough, no Xcode needed).

```sh
./scripts/bundle.sh      # produces build/Mug.app
open build/Mug.app
```

Drag `build/Mug.app` into `/Applications` and add it to Login Items to start it automatically.
