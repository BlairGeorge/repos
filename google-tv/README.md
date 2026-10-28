# Google TV: diagnose, debloat, restore — from your phone

`gtv.sh` talks to your Google TV over **wireless debugging (ADB)** on your home Wi‑Fi.
It never deletes apps: it only *disables* them (`pm disable-user`), and it takes a
backup first so everything can be put back.

## 1. One-time phone setup (Android, Termux)

1. Install **Termux from F-Droid** (the Play Store version is outdated).
2. In Termux:
   ```sh
   pkg update && pkg install android-tools git
   git clone https://github.com/BlairGeorge/repos.git
   cd repos/google-tv
   ```
   (On a PC/Mac with `adb` installed the same commands work.)

### iPhone users: use a computer on the same Wi‑Fi instead

iOS can't run `adb`, so run the same commands from a computer:

- **Mac:** install [Homebrew](https://brew.sh), then in Terminal:
  ```sh
  brew install android-platform-tools git
  git clone https://github.com/BlairGeorge/repos.git && cd repos/google-tv
  ```
- **Windows:** install [Git for Windows](https://git-scm.com/download/win) (includes Git Bash) and
  Google's [SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools);
  unzip Platform-Tools and add that folder to your `PATH`. Then in **Git Bash**:
  ```sh
  git clone https://github.com/BlairGeorge/repos.git && cd repos/google-tv
  ```
- **Linux:** `sudo apt install adb git` (or your distro's equivalent), then clone as above.

`./gtv.sh find` may find nothing on Windows; just use the IP:port shown on the TV.

## 2. Connect to the TV

On the TV: **Settings → System → Developer options → Wireless debugging**.

```sh
./gtv.sh find                          # lists TVs found on the Wi-Fi (may find nothing; that's OK)
./gtv.sh pair 192.168.1.50:41235 123456  # TV: "Pair device with pairing code" (IP:port + code)
./gtv.sh connect 192.168.1.50:37001      # TV: the "IP address & port" line (a different port)
```
Accept the prompt on the TV if one appears.

## 3. Find out why it's slow

```sh
./gtv.sh analyze
```
This checks free memory, storage, CPU load, temperature, the biggest memory users,
and which known bloat is installed. It saves a report in `state/reports/`.
**Share that report and we'll go through the plan together before anything is disabled.**

## 4. Back up, review, apply

```sh
./gtv.sh backup        # saves package states + settings to state/backups/
./gtv.sh plan          # writes state/plan.txt — nothing is changed yet
nano state/plan.txt    # lines without '#' get disabled; add/remove '#' to choose
./gtv.sh apply         # shows the final list and asks you to type "yes"
./gtv.sh reboot
```

How the plan picks its defaults (see `debloat-list.txt`):

| risk   | default in plan | examples |
|--------|-----------------|----------|
| low    | selected        | Play Games, Feedback, Print spooler |
| app    | not selected    | YouTube, Netflix, Prime Video — only if you don't use them |
| medium | not selected    | Voice/Assistant, Chromecast built-in, ambient mode |
| keep   | refused         | Home screen, Play services, Play Store, keyboard, Bluetooth |

Optional speed tweak (also backed up and restorable):
```sh
./gtv.sh animations 0.5
```

## 5. Undo

```sh
./gtv.sh enable com.google.android.katniss   # bring back one app
GTV_DRY_RUN=1 ./gtv.sh restore               # preview a full restore
./gtv.sh restore                             # put everything back as in the latest backup
./gtv.sh restore 20261028-153000             # or a specific backup (ls state/backups)
./gtv.sh status                              # backups + log of every change
```

Restore re-enables (or reinstalls for your user) every package that was enabled in the
backup, re-disables ones that were disabled, and resets the animation settings.
If ADB ever stops working, **Settings → System → Reset** (factory reset) also restores
every disabled system app, but it erases your accounts and apps too.

Keep a copy of the `state/` folder somewhere safe; it holds your backups.
