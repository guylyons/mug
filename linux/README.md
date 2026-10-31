# Mug (Linux)

Linux port of the macOS menu-bar app — a dead simple tray app that keeps your
computer awake. Same menu, same steaming-mug icon.

- Pick **Indefinitely**, 5, 10, 15, 30 minutes, 1 hour or 2 hours.
- **During Work Hours** keeps the machine awake on weekdays between 9 AM and
  5 PM (change with **Set Work Hours…**, which uses `zenity` if installed).
  Remembered across launches.
- The tray mug **steams** while active, and sits empty when off.
- **Also Move Mouse** (optional) nudges the cursor 1px and back after each idle
  minute so chat apps don't mark you away. Needs `xdotool` (and `xprintidle` to
  detect idle); X11 only.
- **Turn Off** (or quitting) lets the computer sleep normally again.

## How it keeps awake

Where macOS holds an IOKit `PreventUserIdleDisplaySleep` assertion, Mug holds
**two** inhibitors for the chosen duration:

- a freedesktop **`org.freedesktop.ScreenSaver`** idle inhibit over D-Bus — this
  is what actually stops the screen from blanking and locking. Desktops
  (GNOME especially) run their own idle timer that *ignores* a plain
  `systemd-inhibit idle` block, so this is the piece that keeps the display on.
- a **`systemd-inhibit`** block on `idle:sleep`, which additionally stops logind
  from auto-suspending (laptops) and acts as the countdown timer — its child
  `sleep` process *is* the timer; when it ends, both inhibitors release.

Check them with:

```sh
systemd-inhibit --list                                   # the suspend block
# idle (screen) inhibit — on GNOME:
busctl --user call org.gnome.SessionManager /org/gnome/SessionManager \
  org.gnome.SessionManager IsInhibited u 8
```

Settings live in `~/.config/mug/config.json`.

## Build & install

Needs the Rust toolchain (no system packages beyond a D-Bus dev lib, which is
already present on any desktop). From this `linux/` directory:

```sh
cargo install --path .    # installs `mug` to ~/.cargo/bin
mug                        # run it
```

### Start it automatically

```sh
cp mug.desktop ~/.config/autostart/
```

### GNOME note

GNOME no longer shows StatusNotifier tray icons on its own. Install the
**“AppIndicator and KStatusNotifierItem Support”** extension
(<https://extensions.gnome.org/extension/615/appindicator-support/>) and the mug
appears in the top bar. KDE, XFCE, Cinnamon, and most panels show it with no
extra setup.

## Differences from the macOS version

- Keep-awake is a `systemd-inhibit` idle/sleep block rather than an IOKit
  display-sleep assertion.
- **Set Work Hours…** uses a `zenity` prompt instead of a native dialog; without
  `zenity` it points you at the config file.
- **Also Move Mouse** uses `xdotool`/`xprintidle` (X11). On Wayland, synthetic
  input is restricted, so this option is a no-op there.
