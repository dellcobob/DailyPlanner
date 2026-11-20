# DailyPlanner

Morning Missions: a daily planner that runs fully offline on your phone. No account, no server, no hosting.

| File | What it is |
| --- | --- |
| `Morning_Missions_Android.apk` | Android app (Android 8 or newer). Same planner, with native save, print, and back button. |
| `Morning_Missions_Tracker.html` | The whole planner in one file. Open it in a browser. |

## What it does

- **Opens on today** in a one-day view. Swipe left or right, or use the arrows, to change days.
- **Check off** objectives. The ring, the day strip, and the hex backdrop fill in as you go.
- **Add, edit, and remove tasks.** Each task has a name, a start and end time, and the weekdays it repeats on (or "This day only").
- **Reorder by dragging** the grip on the right, or press and hold a task. Order never changes a task's time. To change a time, tap the time.
- **Repeating tasks:** when you change or remove one, choose "only this day" or "this day and later". Earlier days always keep what they had.
- **Week view** with seven columns, and **Month view** to look back at any day, see streaks, and open weekly records.
- **Light, dark, or auto** theme, and a 12 or 24-hour clock.

## Storage on the phone

Everything is saved on the device as compact JSON (about 100 bytes per day). In **Tools > Storage** you choose:

- how long to keep full day details (1 month to forever),
- a storage limit (100 KB to 4 MB),
- whether days past a limit keep a tiny score ("9/13") or are deleted,
- whether it asks before archiving.

**Tools > Backups** has Export backup (.json), Restore backup, and Save HTML copy. **Weekly records** download or print a readable week, laid out like the printed schedule. Restore also reads backups from the older Morning Missions tracker.

## Installing the new Android app over the old one

The new APK is signed with a new key, so Android will not install it over the old app. Do this once:

1. In the **old** app, open Save & tools and tap **Export backup (.json)**. Save it to Downloads.
2. Uninstall the old Morning Missions app.
3. Install `Morning_Missions_Android.apk` (allow installs from your file manager if asked).
4. Open it, go to **Tools > Restore backup**, and pick the file from step 1.

Future updates signed with the same key install over the top without losing data.

## For developers

- Tests: `node tests/planner.test.js` (needs the `playwright` package and Chromium).
- Rebuild the APK after editing the HTML:
  `python3 build/build_apk.py --key path/to/key.pem --cert path/to/cert.pem`
  The script swaps the HTML into `build/wrapper.apk` (the native shell), bumps the version with `--version-code`, and signs with APK Signature Scheme v2. It needs Python 3 with the `cryptography` package.
- The signing key is not in this repository. Keep it private and reuse it for every update.
