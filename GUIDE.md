# Work Mac Setup guide

## Quick start

Create local Chrome profiles for the clients you support. Each profile appears in Chrome's built-in profile picker without a linked Google account.

### Create your client profiles

1. Quit Chrome with Command-Q.
2. Enter your client names, one per line.
3. Keep Create Chrome profiles checked.
4. Click Run Setup.
5. Open Chrome and choose a client in the profile picker.

> Tip: Click the items on the left hand side of this help menu, or use the Next button, for a more detailed explanation.

## Client profiles

Enter or paste client names into 1. Client Chrome profiles, one per line. There is no fixed client limit; larger lists take longer to process. The app creates an ordinary local Chrome profile for each new valid name.

### Start with names

```text
Acme
Contoso
Fabrikam
```

Blank lines are ignored. Use distinct names with letters or numbers. The message below the box shows how many client profile(s) are ready or a problem to fix.

### Choose a client in Chrome

Open Chrome, click the profile icon at the top right, and select a client. Each profile has its own cookies, cache, sessions, and browsing history. You can sign in to client websites manually.

The profiles have no linked Google account and Chrome Sync is not enabled. Website sign-in is separate from signing Chrome itself into a Google account.

### Safe reruns

Quit Chrome with Command-Q first. Setup refuses to create profiles while Chrome is running and never quits it for you. Rerunning skips profiles previously created by this app without changing their settings or data. If a name is already a Chrome profile this app didn't create, the message below the client list says so, and Run Setup waits until you rename or remove that client. The existing profile is never changed.

## Colors & start pages

Chrome Profiles can be customized. Add an optional color after a client name, then an optional start page after a spaced vertical bar.

### Color examples

```text
Acme -blue
Contoso -red
Fabrikam -#7B61FF
```

Use lowercase blue, red, green, orange, yellow, purple, pink, teal, or gray. A custom color uses -# followed by six hexadecimal digits.

### Add a start page

```text
Acme -blue | https://portal.example.com
Contoso | https://example.com
```

Keep a space on each side of the vertical bar. A literal tab also works. Use https://, http://, or about:blank. The app requests this as the new profile's startup page, not a new tab every time you select the profile.

Startup pages are best-effort: Chrome can reset this setting on first use. If that happens, set it in that profile's Settings > On startup. The app does not bypass Chrome's preference protection.

> Note: The color sets the new profile's initial theme. Rerunning leaves existing profiles unchanged. Your organization's Chrome policies may override the color or startup page.

## Run setup

Choose which actions to perform, then click Run Setup. Setup runs inside the app, so no Terminal window opens and no administrator password is needed.

### Run Setup

Keep Chrome closed while setup creates profiles. Run Setup runs the selected actions and shows its progress. Guided steps wait for you to click Done in their floating window.

The window lists each selected step in the order it runs and marks it as done, done with a warning, failed, or not run. A failed step shows the reason under its name, and the steps after it still run. Open Details to see the full output, or click Copy to share it. Stop ends setup early; a Chrome profile change that is already in progress finishes first.

### Windows App setting

The checkbox applies and verifies this exact preference for the logged-in user:

```sh
defaults write com.microsoft.rdc.macos ClientSettings.EnforceCredSSPSupport 0
```

Quit and reopen Windows App afterward.

## Login items

Login items is an optional guided step under Actions. You pick the apps in the setup app. When setup reaches this step, it opens System Settings to the Login Items page and shows a small floating window with those apps, ready to drag into the Open at Login list. The setup app never changes login items itself, so no extra macOS permission is requested.

### Pick the apps

Select Open Login Items settings to add selected apps, then expand Apps to add to show the app list. The list stays collapsed until you expand it.

The list shows installed apps from the Applications folders, with their icons. Use the search field to narrow it, then check each app you want to open at login. Your selection is remembered; apps that have since been removed are left out quietly. An empty selection still opens the Login Items page.

### Drag them into Open at Login

1. Run Setup opens System Settings > General > Login Items.
2. A floating Drag into Open at Login window appears beside System Settings with the apps you picked.
3. Drag each app from that window into the Open at Login list. If a drag does not work, click + under Open at Login and choose the app instead.
4. Click Done in the floating window, or close it. Setup continues with the remaining steps. After the last guided step, System Settings closes and the result window appears.

The floating window stays above System Settings and can be moved by its title bar. If the Screen & System Audio Recording action is also selected, System Settings moves to that page after you click Done.

> Note: Because macOS has no permission-free way for one app to add another app to Open at Login, the app does not try. Dragging the apps in yourself keeps the step free of Automation prompts.

## Permissions & privacy

### Screen and audio access

Select Open Screen & System Audio Recording settings, then expand Apps to allow to show the app list. Check the installed apps that need to record the screen, such as meeting or remote-support tools. The step is off by default, the list stays collapsed until you expand it, and your selection is remembered.

When setup reaches this step, it opens Privacy & Security > Screen & System Audio Recording and shows a floating Allow Screen Recording window with those apps. Drag each app from that window into the list, turn on its switch, then click Done in that window, or close it, and setup continues. If a drag does not work, click + and choose the app. The setup app does not grant the permission itself.

### What stays on this Mac

Action choices and the app selections for login items and screen recording are remembered. The pasted client list is not saved in app preferences. Restricted temporary input files are removed when setup finishes.

Chrome profile names and setup records retain the client labels, and Details can show them. Details is not saved; it is discarded when you close the result window. Backups and the setup journal are stored in ~/Library/Application Support/WorkMacSetup. An interrupted run may leave temporary input files behind. Keep passwords and tokens out of client names and URLs.

### Chrome compatibility

Profile creation supports Google Chrome Stable using its standard data folder. It uses Chrome's internal JSON files, which are not a stable public API. Setup backs up Chrome's global Local State file before changing its profile registry and leaves existing profile preferences untouched.

If management disables profile creation, requires Chrome account sign-in, or sets a different user-data folder, setup refuses to proceed. It does not bypass those policies.

## Troubleshooting

Open the issue that matches what you see. The result window marks the step that failed and shows the reason under it. Details has the full output.

### Run Setup is greyed out

Check the message below the client list. It identifies an empty list or the line that needs fixing.

- Enter at least one client name when Create Chrome profiles is selected.
- Remove duplicate entries or make the names distinct. Changing only capitalization or punctuation may still count as a duplicate.
- Rename or remove any client the message says is already a Chrome profile this app didn't create.
- For other setup actions without creating profiles, turn off Create Chrome profiles.

### Chrome is reported as still running

Save your browser work, then use Chrome > Quit Google Chrome (Command-Q). Closing its windows alone does not quit the app.

If the message persists, check Activity Monitor for Google Chrome or its helper processes. Do not force-quit them during profile creation. Finish any active setup run before restarting the Mac, then retry without opening Chrome.

### A client name already exists

The message below the client list names any client that is already a Chrome profile this app didn't create, and Run Setup stays greyed out until you fix it. Remove that client to keep using the existing profile, or rename it to create a new one. Setup never overwrites, renames, or deletes the existing profile.

“Already created by Work Mac Setup; left unchanged” is not an error. It means the profile was recognized and skipped.

### Nothing changed after a run

- “Already created” means that profile was skipped. Changing its input color or start page and rerunning will not update it; make those changes inside that Chrome profile instead.
- “Created local Chrome profile” confirms creation. Open Google Chrome Stable in the same macOS user account and check the profile picker. If it is missing, copy Details and report it to the person who shared the app with you rather than deleting profile folders.
- If a new profile's start page was reset by Chrome, select that profile and set Settings > On startup.

### Chrome is not installed

“Google Chrome is not installed” means setup needs Google Chrome Stable at /Applications/Google Chrome.app before it can create profiles. Install Chrome, then run setup again with only the actions you still need.

### A management policy blocks profile creation

The error names the policy: BrowserAddPersonEnabled blocks extra profiles; BrowserSignin or ForceBrowserSignin may require a Google account; UserDataDir redirects Chrome's data folder.

Report it to the person who shared the app with you so that policy can be reviewed. This app requires local profiles in Chrome's standard data folder; rerunning or granting more permissions will not remove the restriction.

### Setup says recovery is required

An “unfinished profile transaction” or “Recovery is required before another run” means profile creation may have stopped partway through. Stop retrying and keep Chrome closed until the change has been reviewed.

1. Copy the exact error and the backup path from Details.
2. Preserve chrome-profiles-transaction.json and Chrome Profile Backups in ~/Library/Application Support/WorkMacSetup.
3. Report it to the person who shared the app with you so they can review the interrupted change before those profiles are used or modified. Redact client names before sharing error output with anyone else.

> Important: Do not delete the journal to unblock setup, reset Chrome, or replace Local State with a backup blindly. Those actions can lose profile registrations or newer changes.

## Command-line setup

The setup aid also includes scripts for people who prefer Terminal. The packaged Mac app includes its profile helper and does not require Swift or Xcode on the destination Mac.

### Use the standalone folder

When using the repository scripts, run ./build-app.sh once to build the required helper. Copy the example configuration, then edit setup.conf to choose your actions. Quit Chrome before running:

```sh
./build-app.sh
cp setup.conf.example setup.conf
./post-enrollment.sh --enter-clients
```

Paste one client per line and press Return on an empty line to finish. The same color flags work. For a start page in Terminal input, use a literal tab after the name and color, rather than the app's vertical-bar separator.
