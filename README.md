# DailyPlanner

Daily Missions: a planner for your whole day that runs fully offline on your phone. No account, no server, no hosting.

| File | What it is |
| --- | --- |
| `Daily_Missions_Android.apk` | Android app (Android 8 or newer). Same planner, plus notifications, native save, print, and back button. |
| `Daily_Missions.html` | The whole planner in one file. Open it in a browser. |

## What it does

- **Opens on today** in a one-day view. Swipe left or right, or use the arrows, to change days.
- **Check off** objectives. The ring, the day strip, and the hex backdrop fill in as you go.
- **Finish day** plays a rank-up animation for your result. There are 11 tiers, one for each 10% (0 to 9%, 10 to 19%, up to 90 to 99%) plus 100%. Each tier has its own emblem, title, entrance, effects, and its own sound effect, and they build from a calm badge at Recruit to the full Legend celebration. Tap to skip. Sound can be muted on the result screen or in **Tools > Look**, where **Preview a medal** plays any tier's animation and sound without saving anything.
- **Add, edit, and remove tasks.** Each task has a name, a start and end time, and the weekdays it repeats on (or "This day only").
- **Type-ahead names.** As you type a task name, a dropdown suggests tasks you already have, with their usual time and days. Picking one for a new task fills in its time too.
- **Reorder by dragging** the grip on the right, or press and hold a task. Order never changes a task's time. To change a time, tap the time.
- **Repeating tasks:** when you change or remove one, choose "only this day" or "this day and later". Earlier days always keep what they had.
- **Week view** with seven columns, and **Month view** to look back at any day, see streaks, and open weekly records.
- **Notifications (Android app).** In **Tools > Notifications**, turn on any mix of: task reminders (when a task starts, or 5 to 30 minutes before), a morning summary before the first task, an evening finish-day reminder at a time you pick, and a nudge when a task ends without being checked off. One switch turns them all on or off, and **On the lock screen** chooses whether task names show, are hidden on the lock screen, or never show. Reminders arrive even when the app is closed and come back after the phone restarts. **Send a test notification** shows one right away.
- **Light, dark, or auto** theme, and a 12 or 24-hour clock. Light mode uses soft greys instead of bright white, and your theme is applied before the app first draws, so there is no flash on launch.

| Tier | Result | Title |
| --- | --- | --- |
| 1 | 0 to 9% | Recruit |
| 2 | 10 to 19% | Rookie |
| 3 | 20 to 29% | Scout |
| 4 | 30 to 39% | Operative |
| 5 | 40 to 49% | Specialist |
| 6 | 50 to 59% | Vanguard |
| 7 | 60 to 69% | Striker |
| 8 | 70 to 79% | Elite |
| 9 | 80 to 89% | Ace |
| 10 | 90 to 99% | Hero |
| 11 | 100% | Legend |

The animations are original artwork in an Overwatch-inspired style. They do not use any game logos, characters, or audio.

## Storage on the phone

Everything is saved on the device as compact JSON (about 100 bytes per day). In **Tools > Storage** you choose:

- how long to keep full day details (1 month to forever),
- a storage limit (100 KB to 4 MB),
- whether days past a limit keep a tiny score ("9/13") or are deleted,
- whether it asks before archiving.

**Tools > Backups** has Export backup (.json), Restore backup, and Save HTML copy. **Weekly records** download or print a readable week, laid out like the printed schedule. On screen they match your theme (and a downloaded record follows the viewer's light or dark setting); printing is always on white. Restore also reads backups from the older Morning Missions tracker.

## Security and privacy

- **Nothing leaves your phone.** The Android app has no internet permission at all, and the page's Content Security Policy blocks every network connection, so even a bug could not send your data anywhere. There are no accounts, ads, or analytics.
- **Optional app lock (Tools > App lock).** Set a passcode and everything Daily Missions stores is encrypted with AES-256-GCM, using a key made from your passcode with PBKDF2-SHA256 (600,000 rounds). Backups and HTML copies are encrypted too. It locks again after you leave the app (right away, or after 1 to 60 minutes), hides the planner while the app is in the background, and slows down repeated wrong guesses. There is no way to recover a forgotten passcode, so keep a backup.
- **Only the app's own code runs.** The policy allows just the two scripts the page ships with (checked by hash). Weekly records, previews, and downloaded record files can never run scripts, and everything you type is shown as plain text.
- **Backups are checked before use.** Restore refuses damaged or oversized files, ignores unexpected fields, and strips invisible characters that can disguise text.
- **Android app hardening.** No internet permission, backups to the cloud off, cleartext traffic off, file and content access off, it only ever loads its own page, and it refuses all navigation. The only permissions are for notifications: showing them, exact reminder times, and setting reminders again after a restart.
- **Hide from screenshots (Tools > App lock).** In the Android app you can block screenshots, screen recording, and the recent-apps preview.

What the lock cannot cover: someone who knows or watches your passcode, a phone that is already compromised, screenshots (unless you turn on the screenshot block), and unencrypted backups you choose to export. With the lock on, the text of upcoming reminders is stored without encryption so the phone can show it while the app is closed; choose **Never show task names** to keep task names out of it. Without the lock, Android still keeps the app's data private from other apps; if you use the HTML file in a browser instead, other local pages opened in that same browser could read it, so prefer the Android app or turn the lock on.

## Installing on Android

If you already have Daily Missions 2.x, install the new APK over it. Your data stays.

Coming from the original Morning Missions 1.0 app, do this once, because 1.0 was signed with a different key:

1. In the **old** app, open Save & tools and tap **Export backup (.json)**. Save it to Downloads.
2. Uninstall the old app.
3. Install `Daily_Missions_Android.apk` (allow installs from your file manager if asked).
4. Open it, go to **Tools > Restore backup**, and pick the file from step 1.

## For developers

- Tests: `node tests/planner.test.js` (needs the `playwright` package and Chromium). The native reminder logic has JUnit tests in `android/app/src/test`.
- The app icon is the "Quest Ring" set in `android/app/src/main/res` (layered icon, themed one-color icon, and sized PNGs); the status bar icon is made from its one-color layer, and `android/playstore/` has the 512 x 512 image for a Play Store listing.
- The Android app lives in `android/` (Java, no libraries). It shows `Daily_Missions.html` from its assets, which the build copies in. Open the folder in Android Studio, or build with `gradle -p android assembleRelease`.
- GitHub Actions (`.github/workflows/android.yml`) builds the app unsigned on every change, runs the unit tests, and commits the result to `build/shell/app-release-unsigned.apk`. Sign it outside GitHub, so the key never goes there:
  `python3 build/build_apk.py --shell build/shell/app-release-unsigned.apk --key path/to/key.pem --cert path/to/cert.pem`
  The script puts the current HTML in, aligns the APK, and signs it with APK Signature Scheme v2. It needs Python 3 with the `cryptography` package. Bump `versionCode` and `versionName` in `android/app/build.gradle` for each release.
- After editing the HTML, run `python3 build/csp.py` to refresh the script hashes in the Content Security Policy. The APK build refuses to run if they are out of date, and the tests check them too.
- `build/wrapper.apk` is the original prebuilt shell, kept for reference; building from it (without `--shell`) produces the older app without notifications.
- The signing key is not in this repository. Keep it private and reuse it for every update. It can be a password-protected PEM (set `DM_KEY_PASSWORD` or type it when asked); for example `openssl pkcs8 -topk8 -v2 aes-256-cbc -in key.pem -out key-protected.pem`.
- Saved data still uses the `morning-missions-v3` storage key and the app keeps the package id `com.morningmissions.tracker`, so updates keep existing data.
