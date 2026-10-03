# Work Mac setup aid

This setup aid gets a work Mac ready for client work: local Chrome profiles for your clients, the Windows App setting, and guided login items and screen recording permissions.

## Use the Mac app

Open `dist/Work Mac Setup.app`. It provides:

- A **Client list** in **1. Client Chrome profiles**, where you paste client names, one per line. There is no fixed client limit.
- Optional color flags such as `Client Name -blue`, `Client Name -red`, or `Client Name -#7B61FF`.
- An optional start page using `Client Name -blue | https://portal.example.com`.
- An **Actions** section with a checkbox for each setup action, including guided **Login items** and **Screen Recording** steps with searchable pickers of installed apps.
- A **Run Setup** button.
- An **Instructions** button that opens the in-app guide, written in `GUIDE.md` and embedded at build time.

Quit Chrome with **Command-Q**, paste your clients, keep **Create Chrome profiles** checked, and click **Run Setup**. Then open Chrome and choose a client from the profile icon at the top right.

Setup runs inside the app and needs no administrator password. Its window lists each selected step in order and marks it done, failed, or not run, with the reason under any failed step and the full output under **Details**. Client names are not saved in the app's preferences, and the temporary files setup uses are deleted when it finishes.

If a client name is already a Chrome profile this app didn't create, the app flags it under the client list, and Run Setup waits until you rename or remove that client. The existing profile is never changed.

To use the app on another Mac, copy `dist/Work Mac Setup.zip` there, unzip it, and open the app. It contains the script, profile helper, and guide, so that Mac doesn't need Swift or Xcode. If macOS blocks the app the first time, go to **System Settings > Privacy & Security** and click **Open Anyway**.

To rebuild the app after changing its source or scripts:

```sh
./build-app.sh
```

## What it does

- Sets this Windows App preference for the signed-in user and verifies it:

  ```sh
  defaults write com.microsoft.rdc.macos ClientSettings.EnforceCredSSPSupport 0
  ```

- Creates a local Chrome profile for each new client, with its own cookies, cache, sessions, and browsing history. The profiles have no linked Google account, and Chrome Sync stays off.
- Optionally opens **General > Login Items** with a floating **Drag into Open at Login** window listing the apps you picked, so you can drag each one into the list. The app never changes login items itself.
- Optionally opens **Privacy & Security > Screen & System Audio Recording** with a floating **Allow Screen Recording** window, so you can drag each app in and turn on its switch. The app never grants the permission itself.

It does not store passwords, link a Google account, or enable Chrome Sync.

## Command-line use

The app is the easiest way to run setup. To run the script from Terminal instead, run `./build-app.sh` once to build the profile helper, then copy the examples:

```sh
cp setup.conf.example setup.conf
cp clients.tsv.example clients.tsv
chmod 600 setup.conf clients.tsv
```

Edit `setup.conf` to choose the actions you want. For the Login items step, set `OPEN_LOGIN_ITEMS_SETTINGS=1` and list full `.app` paths in `LOGIN_ITEM_APPS`. For the Screen Recording step, set `OPEN_SCREEN_RECORDING_SETTINGS=1` and list the apps in `SCREEN_RECORDING_APPS`. Each step opens the matching System Settings page, shows the app's floating drag window when the built app is available, and continues when you click Done in that window or press Return in Terminal.

Edit `clients.tsv` as `label<TAB>URL<TAB>color`. The color column is optional, and URLs can be `https://`, `http://`, or `about:blank`. `setup.conf` and `clients.tsv` are excluded by `.gitignore`.

Quit Chrome with **Command-Q**, then run the script. It runs as your normal user account and needs no administrator password:

```sh
./post-enrollment.sh
```

To paste client names instead of using `clients.tsv`, run it with `--enter-clients`. Enter one name per line, then press Return on an empty line. Add a color flag such as `-blue` or `-#7B61FF` after a name, and a literal tab before a start page URL:

```text
Acme -blue
Contoso -red<TAB>https://portal.example.com
```

Options:

```text
--config PATH    use a different configuration file
--enter-clients  paste client names instead of reading clients.tsv
--skip-privacy   skip the Screen Recording step
```

## Troubleshooting

- If Chrome isn't installed, install Google Chrome Stable and run setup again. Profiles this app already created are skipped unchanged.
- If Chrome is running, quit it with **Command-Q** before running setup. Setup never quits it for you.
- If a client name is already a Chrome profile this app didn't create, rename or remove that client. The existing profile is never changed.
- The Windows App preference applies to the signed-in user. Quit and reopen Windows App afterward.
