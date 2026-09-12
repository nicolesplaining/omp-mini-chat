# Install OMP Mini Chat with an agent

Use this guide when the user asks you to install OMP Mini Chat on their Mac. Complete the build, terminal integration, app installation, and verification. The user completes provider sign-in.

Repository: https://github.com/nicolesplaining/omp-mini-chat

## 1. Check the Mac and choose a source folder

Run these checks on the user's Mac, not a remote Linux or cloud development environment:

```sh
sw_vers -productVersion
uname -m
xcode-select -p
swift --version
git --version
```

Requirements are macOS 13 or later, Apple Silicon or Intel, Swift 6.0 or later, and internet access. If Apple's developer tools are missing, run `xcode-select --install` and let the user finish Apple's installer. Resume when a compatible Swift toolchain is available. Do not bypass license or administrator prompts.

Use the user's preferred source folder, or `~/Documents/omp-mini-chat` if they have no preference. Clone the repository there if it does not exist. If it already exists, verify its remote and check `git status --short` before reusing it. Preserve local changes; do not reset, clean, or overwrite an unrelated folder. A clean existing checkout can be updated with `git pull --ff-only`.

For a fresh installation:

```sh
mkdir -p "$HOME/Documents"
git clone https://github.com/nicolesplaining/omp-mini-chat.git "$HOME/Documents/omp-mini-chat"
cd "$HOME/Documents/omp-mini-chat"
```

Run the remaining repository commands from that checkout. Read its current README and build scripts before running them. Do not create commits or push installation artifacts.

## 2. Build the bundled runtimes and app

```sh
mkdir -p Vendor
./Scripts/build-synced-omp.sh
./Scripts/build-app.sh
```

Wait for each command to succeed before continuing. The first build downloads large dependencies and can take several minutes. The scripts select the Mac's architecture, download pinned Bun and OMP versions, and package the app. There is no separate Bun installation step. Do not substitute an unpinned runtime or skip checksum verification.

If dependency downloads stall, retry the runtime build with reduced concurrency, then rebuild the app:

```sh
BUN_CONFIG_MAX_HTTP_REQUESTS=8 ./Scripts/build-synced-omp.sh
./Scripts/build-app.sh
```

## 3. Enable terminal integration

```sh
mkdir -p "$HOME/.local/bin"
if [ ! -x "$HOME/.local/bin/omp-stock" ]; then
  install -m 755 Vendor/omp "$HOME/.local/bin/omp-stock"
fi
./Scripts/install-integration.sh
```

The installer preserves an existing executable at `~/.local/bin/omp` as the official fallback, then installs the Mini Chat launcher. The launcher uses the sync runtime by default; `omp --stock` uses the official fallback. Do not delete or reset `~/.omp`, chat history, credentials, or provider settings.

Check `command -v omp`. If it does not resolve to `~/.local/bin/omp`, the user can use that full path immediately. If configuring the short command, prepend `~/.local/bin` in the user's existing shell startup file without replacing the file or duplicating entries. The default macOS zsh shell uses `~/.zshrc`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Existing terminal processes do not gain live sync automatically. Tell the user to start a new OMP session with the installed launcher. Do not terminate their external OMP sessions.

## 4. Install and launch the app

If Mini Chat is already running, check for active work before quitting it normally. Quitting ends OMP terminals owned by Mini Chat. Preserve an existing app bundle as a backup when updating.

Install in `/Applications`, or use `~/Applications` if the user lacks write access. For the standard destination:

```sh
ditto "outputs/OMP Mini Chat.app" "/Applications/OMP Mini Chat.app"
codesign --verify --deep --strict "/Applications/OMP Mini Chat.app"
open "/Applications/OMP Mini Chat.app"
```

If using `~/Applications`, create that directory and use it consistently in all three commands. Do not disable Gatekeeper or other system protections to launch the app.

## 5. Verify and hand off sign-in

Confirm the installed app launches and displays its menu-bar icon and bottom footer. It does not have a regular Dock icon. If desktop interaction tools are available, check the actual UI; otherwise report that visual verification needs the user.

Existing saved chats in `~/.omp/agent/sessions` load automatically. The five most recently updated chats appear in the footer, with the rest under **More**. There is no age cutoff. An empty history will not produce five tabs, and **More** appears only when there are more than five available chats. Never create fake chats to fill the footer.

Tell the user to click **+**, choose a project, and open **Terminal** from the compact Chat popup. They can complete `/login` and `/model` there, then switch back to **Chat**. Let the user enter credentials and complete browser sign-in themselves; do not ask them to paste credentials into your conversation. Do not send a model prompt just to test installation unless the user requests it.

Report the installed app path, whether the build and signature checks passed, whether the footer was visually verified, and any remaining sign-in or PATH step. Do not report completion if a build or installation step failed.

## Updating or removing terminal integration

For an update, preserve local changes, update the clean checkout with `git pull --ff-only`, and repeat the build, integration, and installation steps. `omp update` updates the official fallback only; it does not update Mini Chat's pinned sync runtime.

To restore the official OMP launcher, run `./Scripts/uninstall-integration.sh`. This does not delete the Mini Chat app or the user's chats.
