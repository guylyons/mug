//! Mug — a dead simple Linux tray app that keeps your computer awake.
//!
//! Linux port of the macOS menu-bar app. Where macOS holds an IOKit
//! `PreventUserIdleDisplaySleep` assertion, this holds two inhibitors for the
//! chosen duration:
//!   * a freedesktop `org.freedesktop.ScreenSaver` idle inhibit over D-Bus —
//!     this is what actually keeps the screen from blanking and locking on
//!     GNOME, KDE, XFCE, Cinnamon, …; and
//!   * a `systemd-inhibit` block on `idle:sleep`, which additionally stops
//!     logind from auto-suspending (laptops) and serves as the countdown timer.
//! The tray item is a StatusNotifierItem (works on GNOME, KDE, and anything
//! with an SNI host).

use std::process::{Child, Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use chrono::{Datelike, Local, Timelike, Weekday};
use ksni::menu::{CheckmarkItem, RadioGroup, RadioItem, StandardItem};
use ksni::{Icon, MenuItem, ToolTip, Tray, TrayService};
use serde::{Deserialize, Serialize};

/// Durations offered in the menu, in minutes. `None` means indefinitely.
const OPTIONS: &[(&str, Option<u64>)] = &[
    ("Indefinitely", None),
    ("5 Minutes", Some(5)),
    ("10 Minutes", Some(10)),
    ("15 Minutes", Some(15)),
    ("30 Minutes", Some(30)),
    ("1 Hour", Some(60)),
    ("2 Hours", Some(120)),
];

const REASON: &str = "Mug is keeping this computer awake";

// ---------------------------------------------------------------------------
// Config (persisted to ~/.config/mug/config.json)
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize)]
struct Config {
    #[serde(default = "default_start")]
    work_start: i32, // minutes since midnight
    #[serde(default = "default_end")]
    work_end: i32,
    #[serde(default)]
    work_hours: bool,
    #[serde(default)]
    moves_mouse: bool,
}
fn default_start() -> i32 {
    9 * 60
}
fn default_end() -> i32 {
    17 * 60
}
impl Default for Config {
    fn default() -> Self {
        Config {
            work_start: default_start(),
            work_end: default_end(),
            work_hours: false,
            moves_mouse: false,
        }
    }
}

fn config_path() -> std::path::PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            let home = std::env::var_os("HOME").unwrap_or_default();
            std::path::PathBuf::from(home).join(".config")
        });
    base.join("mug").join("config.json")
}
fn load_config() -> Config {
    std::fs::read_to_string(config_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}
fn save_config(c: &Config) {
    let p = config_path();
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(s) = serde_json::to_string_pretty(c) {
        let _ = std::fs::write(p, s);
    }
}

// ---------------------------------------------------------------------------
// Keeping the machine awake
// ---------------------------------------------------------------------------

/// Spawns `systemd-inhibit ... sleep <secs|infinity>`. The child *is* the
/// timer: when it exits (either because the sleep elapsed or we killed it),
/// the inhibitor is released. `None` == indefinitely.
fn spawn_inhibitor(seconds: Option<u64>) -> Option<Child> {
    if !have("systemd-inhibit") {
        eprintln!("mug: systemd-inhibit not found; cannot keep the system awake");
        return None;
    }
    let sleep_arg = match seconds {
        Some(s) => s.to_string(),
        None => "infinity".to_string(),
    };
    Command::new("systemd-inhibit")
        .args([
            "--what=idle:sleep",
            "--who=Mug",
            &format!("--why={REASON}"),
            "--mode=block",
            "sleep",
            &sleep_arg,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()
}

/// A held `org.freedesktop.ScreenSaver` idle inhibit. GNOME (and KDE/XFCE/…)
/// run their own screen-blank and lock-on-idle timers that ignore logind's
/// `systemd-inhibit idle` block, so blocking suspend alone leaves the screen
/// free to blank and lock. This is the inhibit that actually keeps the display
/// awake — the macOS `PreventUserIdleDisplaySleep` equivalent.
///
/// The inhibit lives as long as the owning D-Bus connection stays open, so we
/// keep the `Connection` alive inside the struct; dropping it (via `UnInhibit`,
/// and the socket closing) releases the inhibit.
struct ScreenInhibit {
    conn: dbus::blocking::Connection,
    cookie: u32,
    /// Unique bus name (e.g. `:1.458`) that owned `org.freedesktop.ScreenSaver`
    /// when we inhibited. If this changes, the service restarted and silently
    /// dropped our inhibit, so we must re-assert it. See `ensure_screen_inhibit`.
    owner: Option<String>,
}

impl ScreenInhibit {
    /// The screensaver service lives under this path on GNOME; some desktops
    /// only answer on the short `/ScreenSaver`, so we try both.
    const PATHS: [&'static str; 2] = ["/org/freedesktop/ScreenSaver", "/ScreenSaver"];

    fn new() -> Option<ScreenInhibit> {
        let conn = dbus::blocking::Connection::new_session().ok()?;
        for path in Self::PATHS {
            let proxy = conn.with_proxy(
                "org.freedesktop.ScreenSaver",
                path,
                Duration::from_secs(5),
            );
            let reply: Result<(u32,), _> = proxy.method_call(
                "org.freedesktop.ScreenSaver",
                "Inhibit",
                ("Mug", REASON),
            );
            if let Ok((cookie,)) = reply {
                let owner = screensaver_owner(&conn);
                return Some(ScreenInhibit { conn, cookie, owner });
            }
        }
        None
    }
}

impl Drop for ScreenInhibit {
    fn drop(&mut self) {
        for path in Self::PATHS {
            let proxy = self.conn.with_proxy(
                "org.freedesktop.ScreenSaver",
                path,
                Duration::from_secs(5),
            );
            let reply: Result<(), _> = proxy.method_call(
                "org.freedesktop.ScreenSaver",
                "UnInhibit",
                (self.cookie,),
            );
            if reply.is_ok() {
                break;
            }
        }
    }
}

/// The unique bus name currently owning `org.freedesktop.ScreenSaver`, or
/// `None` if nobody owns it right now (e.g. the proxy is mid-restart).
fn screensaver_owner(conn: &dbus::blocking::Connection) -> Option<String> {
    let proxy = conn.with_proxy(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        Duration::from_secs(5),
    );
    let (owner,): (String,) = proxy
        .method_call(
            "org.freedesktop.DBus",
            "GetNameOwner",
            ("org.freedesktop.ScreenSaver",),
        )
        .ok()?;
    Some(owner)
}

/// Is `cmd` on PATH?
fn have(cmd: &str) -> bool {
    Command::new("sh")
        .arg("-c")
        .arg(format!("command -v {cmd} >/dev/null 2>&1"))
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

// ---------------------------------------------------------------------------
// Icon (drawn with tiny-skia, same shape as the macOS mug)
// ---------------------------------------------------------------------------

fn icon(steaming: bool) -> &'static Icon {
    static EMPTY: OnceLock<Icon> = OnceLock::new();
    static STEAMING: OnceLock<Icon> = OnceLock::new();
    if steaming {
        STEAMING.get_or_init(|| draw_icon(true))
    } else {
        EMPTY.get_or_init(|| draw_icon(false))
    }
}

fn draw_icon(steaming: bool) -> Icon {
    use tiny_skia::{LineCap, LineJoin, Paint, PathBuilder, Pixmap, Stroke, Transform};
    const S: f32 = 2.0; // supersample 18pt -> 36px
    let dim = (18.0 * S) as u32;
    let mut pm = Pixmap::new(dim, dim).unwrap();

    // Swift coords are y-up in an 18x18 box; flip to tiny-skia's y-down.
    let pt = |x: f32, y: f32| (x * S, (18.0 - y) * S);

    let mut paint = Paint::default();
    paint.set_color_rgba8(255, 255, 255, 255); // white; most Linux panels are dark
    paint.anti_alias = true;

    let stroke = |w: f32| Stroke {
        width: w * S,
        line_cap: LineCap::Round,
        line_join: LineJoin::Round,
        ..Default::default()
    };

    // Cup body (rounded bottom corners approximated with quads at the tangent pts).
    let mut b = PathBuilder::new();
    let (x, y) = pt(2.5, 10.0);
    b.move_to(x, y);
    let (x, y) = pt(2.5, 4.0);
    b.line_to(x, y);
    let (cx, cy) = pt(2.5, 1.5);
    let (x, y) = pt(5.0, 1.5);
    b.quad_to(cx, cy, x, y);
    let (x, y) = pt(10.0, 1.5);
    b.line_to(x, y);
    let (cx, cy) = pt(12.5, 1.5);
    let (x, y) = pt(12.5, 4.0);
    b.quad_to(cx, cy, x, y);
    let (x, y) = pt(12.5, 10.0);
    b.line_to(x, y);
    if let Some(path) = b.finish() {
        pm.stroke_path(&path, &paint, &stroke(1.5), Transform::identity(), None);
    }

    // Rim.
    let mut r = PathBuilder::new();
    let (x, y) = pt(2.5, 10.0);
    r.move_to(x, y);
    let (x, y) = pt(12.5, 10.0);
    r.line_to(x, y);
    if let Some(path) = r.finish() {
        pm.stroke_path(&path, &paint, &stroke(1.5), Transform::identity(), None);
    }

    // Handle.
    let mut h = PathBuilder::new();
    let (x, y) = pt(12.5, 8.5);
    h.move_to(x, y);
    let (c1x, c1y) = pt(16.5, 8.5);
    let (c2x, c2y) = pt(16.5, 3.5);
    let (x, y) = pt(12.5, 3.5);
    h.cubic_to(c1x, c1y, c2x, c2y, x, y);
    if let Some(path) = h.finish() {
        pm.stroke_path(&path, &paint, &stroke(1.5), Transform::identity(), None);
    }

    // Steam.
    if steaming {
        for sx in [5.0_f32, 9.0] {
            let mut s = PathBuilder::new();
            let (x, y) = pt(sx, 11.75);
            s.move_to(x, y);
            let (c1x, c1y) = pt(sx + 1.75, 13.5);
            let (c2x, c2y) = pt(sx - 1.75, 15.0);
            let (x, y) = pt(sx, 16.75);
            s.cubic_to(c1x, c1y, c2x, c2y, x, y);
            if let Some(path) = s.finish() {
                pm.stroke_path(&path, &paint, &stroke(1.25), Transform::identity(), None);
            }
        }
    }

    // tiny-skia is premultiplied RGBA little-endian; SNI wants ARGB32 network order.
    let mut data = Vec::with_capacity(pm.data().len());
    for px in pm.data().chunks_exact(4) {
        data.extend_from_slice(&[px[3], px[0], px[1], px[2]]);
    }
    Icon {
        width: dim as i32,
        height: dim as i32,
        data,
    }
}

// ---------------------------------------------------------------------------
// Tray
// ---------------------------------------------------------------------------

struct Mug {
    active: bool,
    selected: Option<usize>,
    end: Option<Instant>, // None while active == running indefinitely
    work_hours: bool,
    work_start: i32,
    work_end: i32,
    moves_mouse: bool,
    inhibitor: Option<Child>,
    screen: Option<ScreenInhibit>,
    last_jiggle: Instant,
    has_xdotool: bool,
    has_xprintidle: bool,
}

impl Mug {
    fn new() -> Self {
        let c = load_config();
        let mut m = Mug {
            active: false,
            selected: None,
            end: None,
            work_hours: false,
            work_start: c.work_start,
            work_end: c.work_end,
            moves_mouse: c.moves_mouse,
            inhibitor: None,
            screen: None,
            last_jiggle: Instant::now(),
            has_xdotool: have("xdotool"),
            has_xprintidle: have("xprintidle"),
        };
        if c.work_hours {
            m.set_work_hours(true);
        }
        m
    }

    fn persist(&self) {
        save_config(&Config {
            work_start: self.work_start,
            work_end: self.work_end,
            work_hours: self.work_hours,
            moves_mouse: self.moves_mouse,
        });
    }

    /// Start keeping awake for `minutes` (None = indefinitely).
    fn start(&mut self, minutes: Option<u64>) {
        self.stop_inhibitor();
        let secs = minutes.map(|m| m * 60);
        self.inhibitor = spawn_inhibitor(secs);
        self.screen = ScreenInhibit::new();
        self.active = self.inhibitor.is_some() || self.screen.is_some();
        self.end = secs
            .filter(|_| self.active)
            .map(|s| Instant::now() + Duration::from_secs(s));
    }

    fn stop_inhibitor(&mut self) {
        if let Some(mut child) = self.inhibitor.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.screen = None; // Drop releases the ScreenSaver inhibit.
        self.active = false;
        self.end = None;
    }

    fn turn_off(&mut self) {
        self.set_work_hours(false);
        self.stop_inhibitor();
        self.selected = None;
    }

    fn set_work_hours(&mut self, on: bool) {
        self.work_hours = on;
        self.persist();
        if on {
            self.selected = None;
            self.stop_inhibitor();
            self.check_work_hours();
        } else {
            // leave any manual session alone? macOS turns everything off when leaving work mode
        }
    }

    /// Seconds remaining in today's work window, or None if outside it (weekends count as outside).
    fn work_seconds_left(&self) -> Option<u64> {
        let now = Local::now();
        if matches!(now.weekday(), Weekday::Sat | Weekday::Sun) {
            return None;
        }
        let cur = now.hour() as i32 * 60 + now.minute() as i32;
        if cur >= self.work_start && cur < self.work_end {
            let secs = (self.work_end - cur) as i64 * 60 - now.second() as i64;
            Some(secs.max(0) as u64)
        } else {
            None
        }
    }

    fn check_work_hours(&mut self) {
        match self.work_seconds_left() {
            Some(left) if !self.active => self.start_timed(left),
            None if self.active => self.stop_inhibitor(),
            _ => {}
        }
    }

    /// Like `start` but takes raw seconds (used by work-hours mode).
    fn start_timed(&mut self, seconds: u64) {
        self.stop_inhibitor();
        self.inhibitor = spawn_inhibitor(Some(seconds));
        self.screen = ScreenInhibit::new();
        self.active = self.inhibitor.is_some() || self.screen.is_some();
        self.end = if self.active {
            Some(Instant::now() + Duration::from_secs(seconds))
        } else {
            None
        };
    }

    /// Called ~once a second by the background ticker.
    fn tick(&mut self) {
        // Has a timed session elapsed? Either the systemd-inhibit child exited
        // on its own, or (where there is no child) the deadline has passed.
        let child_done = matches!(
            self.inhibitor.as_mut().map(|c| c.try_wait()),
            Some(Ok(Some(_)))
        );
        let deadline_passed = matches!(self.end, Some(end) if Instant::now() >= end);
        if self.active && (child_done || deadline_passed) {
            self.stop_inhibitor(); // drops the child and the screen inhibit, clears active/end
            if !self.work_hours {
                self.selected = None;
            }
        }
        if self.work_hours {
            self.check_work_hours();
        }
        self.ensure_screen_inhibit();
        self.maybe_jiggle();
    }

    /// Keep the `org.freedesktop.ScreenSaver` inhibit alive across service
    /// restarts. GNOME's `gsd-screensaver-proxy` (and equivalents) can be
    /// restarted out from under us — e.g. when the settings daemon reloads —
    /// which drops every inhibit it was tracking. Our D-Bus connection stays
    /// open and our cookie still looks valid on our side, so nothing fails and
    /// nothing notices: the screen just quietly starts locking again while Mug
    /// still shows as active. Guard against that by re-inhibiting whenever the
    /// owner of the name changes, and by retrying if we never got one.
    fn ensure_screen_inhibit(&mut self) {
        if !self.active {
            return;
        }
        match &self.screen {
            Some(s) => {
                // A changed owner means a fresh service instance that has no
                // record of our cookie; re-inhibit against it. A momentarily
                // absent owner (None) is a restart in progress — wait for the
                // new owner rather than churn.
                if let Some(current) = screensaver_owner(&s.conn) {
                    if Some(&current) != s.owner.as_ref() {
                        self.screen = ScreenInhibit::new();
                    }
                }
            }
            // The service was down when we started (or a re-inhibit just
            // failed); keep trying until it answers.
            None => self.screen = ScreenInhibit::new(),
        }
    }

    fn maybe_jiggle(&mut self) {
        if !(self.moves_mouse && self.active && self.has_xdotool) {
            return;
        }
        if self.last_jiggle.elapsed() < Duration::from_secs(60) {
            return;
        }
        self.last_jiggle = Instant::now();
        // Only nudge if the user has actually been idle, so we never fight real input.
        if self.has_xprintidle {
            if let Some(ms) = idle_ms() {
                if ms < 55_000 {
                    return;
                }
            }
        }
        let _ = Command::new("xdotool")
            .args(["mousemove_relative", "--", "1", "0"])
            .status();
        let _ = Command::new("xdotool")
            .args(["mousemove_relative", "--", "-1", "0"])
            .status();
    }

    fn work_hours_label(&self) -> String {
        format!(
            "{}–{}",
            fmt_time(self.work_start),
            fmt_time(self.work_end)
        )
    }

    fn status_text(&self) -> String {
        if !self.active {
            return if self.work_hours {
                "Waiting for work hours — computer can sleep".into()
            } else {
                "Mug is empty — computer can sleep".into()
            };
        }
        match self.end {
            None => "Keeping awake indefinitely".into(),
            Some(end) => {
                let remaining = end.saturating_duration_since(Instant::now()).as_secs();
                format!("Keeping awake — {} left", fmt_remaining(remaining))
            }
        }
    }

    fn open_work_hours_dialog(&mut self) {
        // Use zenity if present; otherwise point the user at the config file.
        if !have("zenity") {
            notify(
                "Set Work Hours",
                &format!("Install zenity, or edit {}", config_path().display()),
            );
            return;
        }
        let ask = |label: &str, cur: i32| -> Option<i32> {
            let out = Command::new("zenity")
                .args([
                    "--entry",
                    &format!("--title=Work Hours"),
                    &format!("--text={label} (HH:MM)"),
                    &format!("--entry-text={}", fmt_time24(cur)),
                ])
                .output()
                .ok()?;
            if !out.status.success() {
                return None;
            }
            parse_hhmm(String::from_utf8_lossy(&out.stdout).trim())
        };
        if let (Some(start), Some(end)) = (ask("From", self.work_start), ask("To", self.work_end)) {
            if start < end {
                self.work_start = start;
                self.work_end = end;
                self.set_work_hours(true);
            } else {
                notify("Work Hours", "End time must be after start time.");
            }
        }
    }
}

impl Drop for Mug {
    fn drop(&mut self) {
        self.stop_inhibitor();
    }
}

impl Tray for Mug {
    fn id(&self) -> String {
        "mug".into()
    }
    fn title(&self) -> String {
        "Mug".into()
    }
    fn icon_pixmap(&self) -> Vec<Icon> {
        vec![icon(self.active).clone()]
    }
    fn tool_tip(&self) -> ToolTip {
        ToolTip {
            title: if self.active {
                "Mug: keeping your computer awake".into()
            } else {
                "Mug: off".into()
            },
            description: String::new(),
            icon_name: String::new(),
            icon_pixmap: Vec::new(),
        }
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let mouse_label = if self.moves_mouse && !self.has_xdotool {
            "Also Move Mouse (needs xdotool)".to_string()
        } else {
            "Also Move Mouse".to_string()
        };

        vec![
            StandardItem {
                label: self.status_text(),
                enabled: false,
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            RadioGroup {
                selected: self.selected.unwrap_or(usize::MAX),
                select: Box::new(|m: &mut Mug, idx| {
                    m.set_work_hours(false);
                    m.selected = Some(idx);
                    m.start(OPTIONS[idx].1);
                }),
                options: OPTIONS
                    .iter()
                    .map(|(label, _)| RadioItem {
                        label: label.to_string(),
                        ..Default::default()
                    })
                    .collect(),
            }
            .into(),
            MenuItem::Separator,
            CheckmarkItem {
                label: format!("During Work Hours ({})", self.work_hours_label()),
                checked: self.work_hours,
                activate: Box::new(|m: &mut Mug| {
                    let on = !m.work_hours;
                    m.set_work_hours(on);
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Set Work Hours…".into(),
                activate: Box::new(|m: &mut Mug| m.open_work_hours_dialog()),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            CheckmarkItem {
                label: mouse_label,
                checked: self.moves_mouse,
                activate: Box::new(|m: &mut Mug| {
                    m.moves_mouse = !m.moves_mouse;
                    m.last_jiggle = Instant::now() - Duration::from_secs(60);
                    m.persist();
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Turn Off".into(),
                enabled: self.active || self.work_hours,
                activate: Box::new(|m: &mut Mug| m.turn_off()),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Quit Mug".into(),
                activate: Box::new(|_: &mut Mug| std::process::exit(0)),
                ..Default::default()
            }
            .into(),
        ]
    }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn idle_ms() -> Option<u64> {
    let out = Command::new("xprintidle").output().ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse().ok()
}

fn notify(title: &str, body: &str) {
    if have("notify-send") {
        let _ = Command::new("notify-send").args([title, body]).status();
    } else {
        eprintln!("mug: {title}: {body}");
    }
}

fn parse_hhmm(s: &str) -> Option<i32> {
    let (h, m) = s.split_once(':')?;
    let h: i32 = h.trim().parse().ok()?;
    let m: i32 = m.trim().parse().ok()?;
    if (0..24).contains(&h) && (0..60).contains(&m) {
        Some(h * 60 + m)
    } else {
        None
    }
}

/// 12-hour clock, e.g. "9:00 AM".
fn fmt_time(minutes: i32) -> String {
    let (h, m) = (minutes / 60, minutes % 60);
    let (h12, ap) = match h {
        0 => (12, "AM"),
        1..=11 => (h, "AM"),
        12 => (12, "PM"),
        _ => (h - 12, "PM"),
    };
    format!("{h12}:{m:02} {ap}")
}

/// 24-hour "HH:MM" for prefilling the dialog.
fn fmt_time24(minutes: i32) -> String {
    format!("{:02}:{:02}", minutes / 60, minutes % 60)
}

fn fmt_remaining(secs: u64) -> String {
    if secs >= 3600 {
        format!("{}h {}m", secs / 3600, (secs % 3600) / 60)
    } else {
        format!("{}m {}s", secs / 60, secs % 60)
    }
}

// ---------------------------------------------------------------------------

fn main() {
    let service = TrayService::new(Mug::new());
    let handle = service.handle();
    service.spawn();

    // Tick once a second: advance timers, enforce work hours, refresh the
    // countdown, and jiggle the mouse if asked.
    loop {
        std::thread::sleep(Duration::from_secs(1));
        handle.update(|m: &mut Mug| m.tick());
    }
}
