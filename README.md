# OMP Mini Chat

An always-on-top macOS footer for [Oh My Pi](https://github.com/can1357/oh-my-pi), with resizable chat popups and automatic encrypted synchronization with active terminal sessions.

## Requirements

- macOS 13 or later. The build scripts support Apple Silicon and Intel Macs.
- Apple Command Line Tools with Swift 5.9 or later. If needed, run `xcode-select --install` in Terminal and finish the installer before continuing.
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

### 4. Sign in to OMP

Launch OMP in Terminal:

```sh
"$HOME/.local/bin/omp"
```

Complete the first-run provider setup. If you already passed setup, type `/login` and select your provider, then use `/model` to choose a model. Mini Chat uses the same OMP login. Complete this step in Terminal before sending messages in Mini Chat.

To use the shorter `omp` command, add `export PATH="$HOME/.local/bin:$PATH"` to your shell configuration if it is not already there. For the default macOS zsh shell, that file is `~/.zshrc`. Open a new Terminal window afterward.

### 5. Install and open Mini Chat

Quit any running copy of Mini Chat before replacing it. From the source folder, run:

```sh
ditto "outputs/OMP Mini Chat.app" "/Applications/OMP Mini Chat.app"
open "/Applications/OMP Mini Chat.app"
```

Mini Chat runs as a menu-bar app, with a footer at the bottom of your screen. It does not appear as a regular Dock app.

## Everyday use

- Run `omp` from your project folder. Active terminal sessions appear in Mini Chat automatically; keep the terminal session open for live sync.
- Click a footer tab to open its chat. Multiple popups can stay open, and each can be dragged, resized, or minimized independently.
- A spinner means the agent is working. A blue dot means there is an unread response.
- Use the menu-bar icon to show or hide the footer, or quit Mini Chat. `Control` + `Option` + `Space` toggles the Mini Chat windows.

## Troubleshooting and updates

- **“No models available”**: finish sign-in and model selection in OMP Terminal, then reopen the Mini Chat popup.
- **`omp: command not found`**: use `~/.local/bin/omp` or add `~/.local/bin` to your PATH as described above.
- **Dependency downloads stall**: retry step 2 with `BUN_CONFIG_MAX_HTTP_REQUESTS=8 ./Scripts/build-synced-omp.sh`, then run `./Scripts/build-app.sh`.
- **No live sync**: start a fresh terminal session using `~/.local/bin/omp`. The host and Mini Chat need access to OMP's encrypted relay. `omp --stock` runs official OMP without automatic Mini Chat hosting.

`omp update` updates only the official fallback. The sync runtime stays pinned to OMP 18.1.4. To update Mini Chat, pull the latest source with `git pull`, repeat steps 2 and 3, then replace the app using step 5.

To restore official OMP as the default, run `./Scripts/uninstall-integration.sh` from the source folder. This restores the terminal command; it does not remove the Mini Chat app.
