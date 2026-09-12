# OMP Mini Chat

An always-on-top macOS footer for [Oh My Pi](https://github.com/can1357/oh-my-pi), with resizable popups, a full embedded OMP terminal, and a compact chat view of the same session.

## Requirements

- macOS 13 or later. The build scripts support Apple Silicon and Intel Macs.
- Apple Command Line Tools with Swift 6.0 or later. If needed, run `xcode-select --install` in Terminal and finish the installer before continuing.
- An internet connection and an account with an OMP-supported model provider.

You do not need to install Bun or OMP separately. The scripts download their pinned versions.

## Download and install

There is currently no prebuilt app download. Build the app from source using Terminal.

### 1. Download the source

Run these commands from the folder where you want to keep the source:

```sh
git clone https://github.com/nicolesplaining/omp-mini-chat.git
cd omp-mini-chat
```

### 2. Build the app and sync runtime

Run the remaining setup commands from the `omp-mini-chat` folder. The first build downloads large dependencies and can take several minutes.

```sh
mkdir -p Vendor
./Scripts/build-synced-omp.sh
./Scripts/build-app.sh
```

The finished app is at `outputs/OMP Mini Chat.app`. Wait for each command to finish successfully before continuing.

### 3. Enable terminal sync

Create the official OMP fallback if it is missing, then install the sync launcher:

```sh
mkdir -p "$HOME/.local/bin"
if [ ! -x "$HOME/.local/bin/omp-stock" ]; then
  install -m 755 Vendor/omp "$HOME/.local/bin/omp-stock"
fi
./Scripts/install-integration.sh
```

The installer preserves an existing `~/.local/bin/omp` as the official fallback. It installs the sync-enabled launcher at `~/.local/bin/omp`.

### 4. Install and open Mini Chat

Quit any running copy of Mini Chat before replacing it. From the source folder, run:

```sh
ditto "outputs/OMP Mini Chat.app" "/Applications/OMP Mini Chat.app"
open "/Applications/OMP Mini Chat.app"
```

Mini Chat runs as a menu-bar app, with a footer at the bottom of your screen. It does not appear as a regular Dock app.

### 5. Sign in inside Mini Chat

Click **+** in the footer and choose a project folder. The popup opens in Chat at the compact 370 × 480 size. Click **Terminal** for first-run provider setup and sign-in. You can also type `/login`, then `/model` to choose a model. OAuth sign-in opens your browser when needed; return to the popup for any requested code.

Use **Terminal** in the popup header for full OMP controls, then **Chat** to return to the conversation. Switching views keeps the same session and window size. You can resize the popup yourself. Chat connects through the encrypted relay; the terminal works independently of that connection. Tabs and popup headings show the chat name, or its first message until OMP gives it a name.

OMP credentials are shared with your ordinary terminal. To use OMP outside Mini Chat, run `~/.local/bin/omp`. For the shorter `omp` command, add `export PATH="$HOME/.local/bin:$PATH"` to your shell configuration if needed. The default macOS zsh shell uses `~/.zshrc`; open a new Terminal window afterward.

## Everyday use

- Use the embedded **Terminal** for slash commands, completion menus, settings, shell commands, keyboard shortcuts, and interactive extensions. This runs OMP itself, using [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal rendering.
- Adjust transparency with **… → Opacity…** in a popup. The slider controls chat background opacity from 10–100%, with 100% fully opaque. Text stays crisp. The default matches the original background, 50% in light mode or 52% in dark mode. **Reset to default** restores it, and your setting is saved automatically.
- New sessions started with **+** run inside Mini Chat. Minimizing a popup keeps its terminal running; quitting Mini Chat ends the terminals it owns.
- Sessions started in an external terminal still appear automatically in the chat view. Their terminal screen stays in that app. For full controls inside Mini Chat, start a session with **+**, or close the external host before opening its saved session and clicking the terminal button. Mini Chat never takes over a running external terminal.
- Click a footer tab to open its chat. Multiple popups can stay open, and each can be dragged, resized, or minimized independently.
- A spinner means the agent is working. A blue dot means there is an unread response.
- Use the menu-bar icon to show or hide the footer, or quit Mini Chat. `Control` + `Option` + `Space` toggles the Mini Chat windows.

## Troubleshooting and updates

- **“No models available”**: open the popup's **Terminal** view and use `/login`, then `/model`. You can complete first-time setup entirely inside Mini Chat.
- **`omp: command not found`**: use `~/.local/bin/omp` or add `~/.local/bin` to your PATH as described above.
- **Dependency downloads stall**: retry step 2 with `BUN_CONFIG_MAX_HTTP_REQUESTS=8 ./Scripts/build-synced-omp.sh`, then run `./Scripts/build-app.sh`.
- **No live sync**: start a fresh terminal session using `~/.local/bin/omp`. The host and Mini Chat need access to OMP's encrypted relay. `omp --stock` runs official OMP without automatic Mini Chat hosting.

`omp update` updates only the official fallback. The sync runtime stays pinned to OMP 18.1.4. To update Mini Chat, pull the latest source with `git pull`, repeat steps 2 and 3, then replace the app using step 4.

To restore official OMP as the default, run `./Scripts/uninstall-integration.sh` from the source folder. This restores the terminal command; it does not remove the Mini Chat app.
