# Changelog

## 1.0.1

- Fix apps (Settings, Sileo and others) hanging on launch on some setups: TopRow no longer calls UIKit while the app is still loading.
- CarPlay keyboards stay stock. The car screen keeps its keyboard height, so the extra row covered the letters.
- Share Diagnostics now also includes TopRow's log from every app (SpringBoard, Spotlight and the rest, not just Settings) and the last 3 days of iOS crash and hang reports. Reports where TopRow is on the crashed or stuck thread get that thread's stack, and the full report when it isn't huge.

## 1.0.0

- First release: a number row on the stock keyboard (1–0 on letters, symbols with Shift / Caps Lock, an extra symbol row on 123), editable rows, symbol hints, Key Height and Bottom Area sliders, landscape rows, 123/ABC labels, per-app and per-keyboard-type control, live settings and Share Diagnostics.
