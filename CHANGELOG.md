# Changelog

## [Unreleased]

### Changed
- **Shizuku uptime moved to About screen**: no longer shown in the home screen banner. Find it under Settings → About as its own tile, still live-updating.
- **Home screen banner only shows when action is needed**: the "Shizuku active" banner is now hidden entirely once Shizuku is ready. It still appears with a warning and "Tap to fix" for not-running, not-installed, or permission-denied states.

## [1.0.5] - 2026-09-09

### Added
- **GPLv3 license** and F-Droid/IzzyOnDroid fastlane metadata for FOSS store listings.

### Changed
- **Bundled Inter font** instead of fetching it at runtime via `google_fonts`, removing the only network dependency in the app.

## [1.0.4] - 2026-09-08

### Added

#### App relaunch
- **Restore previous app after relaunch**: when a service can only be recovered by fully relaunching its app, Service Keeper now captures whatever app was in the foreground beforehand and switches back to it afterward, instead of always going to the home screen.
- **Idle-aware relaunch gating**: new Settings > App relaunch section controls when that relaunch is allowed to interrupt you:
  - **Always**: relaunch immediately, even mid-use
  - **No app open**: only when the home screen is showing
  - **No activity for a while**: only after N seconds with no taps or scrolls anywhere on the device (15s to 5min presets), detected via `PowerManager`'s own activity timer (`dumpsys power`), not `UsageEvents`, since the latter doesn't fire reliably during ongoing scrolling
  - **When locked**: only right after you unlock the phone
  - A relaunch blocked by the current setting is queued and retried automatically once idle, polled every 10s, or immediately on unlock for the locked mode, instead of waiting for the next incidental service-stop detection

#### UI / Cards
- **Reusable `AppGroupCard` widget** — sliver-based expandable card with sticky header, used across all three monitoring screens (Services, Accessibility, Notifications). Replaces three separate header delegate implementations.
- **3-state group toggle** — each app card header now has a compact toggle controlling the monitoring state for all services in the group:
  - **Off** (`block`) — not monitored
  - **Monitor** (`eye`) — watched silently, no notifications
  - **Notify** (`bell`) — watched and notified on restart
- **State-aware toggle icons** — icons reflect the current selection contextually. Off state: grey closed eye + grey mute. Monitor state: green check + green open eye + grey mute. Notify state: green check + green open eye + green bell.
- **Toggle explainer banner** — global dismissable banner at the top of the app explaining the 3-state toggle with inline icons and descriptions. Restored via Settings → Reset dismissed banners.
- ** Added **Report Issue** to easily report issues on Github
- **Multi-select Apps and Services** to enable / disable

#### Undo
- **Undo snackbar** — toggling a group state shows a 10-second snackbar with an animated countdown progress bar and an Undo button.
- **AppBar undo action** — the 3-dot menu shows "Undo: [last action]" while the snackbar is active.
- **Reliable auto-dismiss** — undo timer is managed in the shell; snackbar and AppBar action are cleared together after exactly 10 seconds regardless of Flutter's SnackBar duration behavior.

### Changed

- **Notification Monitor screen** — replaced the custom `_NotifGroupHeaderDelegate` with `AppGroupCard`. The old separate monitor switch + notification bell icon + popup are unified into the same 3-state toggle used by all other screens.

### Fixed

- **Notification screen card spacing** — extra 8 px spacers between cards removed; spacing now matches the Services and Accessibility screens.
- **Added option to restart entire app** if service fails to start
