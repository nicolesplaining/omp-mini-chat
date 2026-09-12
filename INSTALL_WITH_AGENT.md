# Install OMP Mini Chat with an agent

Build, install, and verify OMP Mini Chat on the user's Mac. This guide uses a local source build. Provider sign-in belongs to the user. Terminal sync is optional and is not required to use Mini Chat.

Repository: https://github.com/nicolesplaining/omp-mini-chat

## 1. Check the environment

Run these commands on the user's Mac, not a remote Linux or cloud development environment:

```sh
sw_vers -productVersion
uname -m
xcode-select -p
swift --version
git --version
```

Requirements are macOS 13 or later, Apple Silicon or Intel, Swift 6.0 or later, and internet access. Do not install a separate Bun or OMP; the build scripts download pinned versions.

If developer tools are missing, run `xcode-select --install` and let the user finish Apple's installer. Resume when a compatible Swift toolchain is available. If Swift is older than 6.0, explain that the toolchain needs updating before the build can continue. Do not repeatedly retry a build with an incompatible compiler.

## 2. Get the source

Use the user's preferred source folder, or `~/Documents/omp-mini-chat`. For an existing folder, check its remote and `git status --short` before reusing it. Preserve local changes and unrelated files. Only update a clean matching checkout with `git pull --ff-only`.

For a fresh checkout:

```sh
mkdir -p "$HOME/Documents"
git clone https://github.com/nicolesplaining/omp-mini-chat.git "$HOME/Documents/omp-mini-chat"
cd "$HOME/Documents/omp-mini-chat"
```

Read that checkout's README and build scripts. Run the remaining build commands from its root. Do not create commits or push installation artifacts.

## 3. Build

Run each command only after the previous command succeeds:

```sh
mkdir -p Vendor
BUN_CONFIG_MAX_HTTP_REQUESTS=8 ./Scripts/build-synced-omp.sh
./Scripts/build-app.sh
```

The first build downloads large dependencies and may take several minutes. Tell the user which stage is running instead of leaving them waiting without an update. The finished app is `outputs/OMP Mini Chat.app`.

If a download fails, report the failed host and retry the failed stage once. Preserve useful build output. Do not repeatedly restart the entire installation, substitute unpinned runtimes, or skip checksums. If compilation fails, report the actual error rather than proceeding to installation.

## 4. Install and open

Choose `/Applications`, or `~/Applications` if it is not writable. If Mini Chat is already running, check for active work before quitting it normally. Quitting ends OMP terminals owned by Mini Chat. Preserve an existing installed app as a backup before replacing it, and do not stop external OMP terminal sessions.

```sh
OMP_MINI_APP_DIR=/Applications
if [ ! -w "$OMP_MINI_APP_DIR" ]; then
  OMP_MINI_APP_DIR="$HOME/Applications"
  mkdir -p "$OMP_MINI_APP_DIR"
fi
OMP_MINI_APP_PATH="$OMP_MINI_APP_DIR/OMP Mini Chat.app"
ditto "outputs/OMP Mini Chat.app" "$OMP_MINI_APP_PATH"
codesign --verify --deep --strict "$OMP_MINI_APP_PATH"
open "$OMP_MINI_APP_PATH"
```

Open the installed app, not the copy in the source outputs. The signature command checks the local bundle's integrity. If opening fails or macOS prompts for user action, report the exact message and let the user handle it; do not disable system protections or remove quarantine flags.

Confirm the menu-bar icon and bottom footer are visible. There is no regular Dock icon. Use desktop interaction tools when available. Otherwise ask the user to confirm the footer and mark visual verification as pending until they do. An `open` command returning success alone does not prove the footer is visible.

## 5. Check history and hand off sign-in

Existing saved chats in `~/.omp/agent/sessions` load automatically, with no age cutoff. The footer shows up to five recently updated chats; **More** appears only when additional chats exist. An empty history is a valid result. Do not fabricate chats to fill five tabs or claim history imported without checking it.

If an account is not configured, guide the user to **+ → choose a project folder → Terminal → /login → /model → Chat**. They enter credentials and complete browser sign-in themselves. Do not ask them to paste credentials into your conversation. Do not send a model prompt merely to test installation unless requested. The installation can be verified before provider sign-in, but chat readiness remains pending.

## 6. Optional: connect the user's normal OMP terminal

Skip this section for users who only want to chat inside Mini Chat. If they want sessions from their ordinary terminal to appear live, run the installer from the actual installed app path:

```sh
/bin/zsh "$OMP_MINI_APP_PATH/Contents/Resources/install-integration.sh"
"$HOME/.local/bin/omp" --version
"$HOME/.local/bin/omp" --stock --version
```

The installer preserves an existing executable at `~/.local/bin/omp` as `omp-stock`, installs the sync launcher, and supplies the bundled official fallback on a fresh machine. Preserve `~/.omp`, chat history, credentials, and provider settings.

Use `~/.local/bin/omp` immediately. For the short `omp` command, check `command -v omp` and configure the user's shell only if needed. Prepend `export PATH="$HOME/.local/bin:$PATH"` to the existing startup file without replacing its contents or duplicating the entry. The default macOS zsh shell uses `~/.zshrc`. Tell the user to open a new terminal and start OMP with this launcher; already-running external sessions do not gain sync automatically.

## Report the result

Keep the final message short. Include the installed app path and concrete status: build and bundle checks passed, footer verified or pending, provider sign-in ready or pending, and terminal sync installed or skipped. Include any user action still needed. Do not call the app ready to chat merely because it copied successfully.

For updates, update a clean source checkout, rebuild, and replace the installed app. Preserve the old app until the replacement opens successfully. `omp update` updates the official fallback, not Mini Chat's pinned sync runtime. Run `./Scripts/uninstall-integration.sh` from the checkout to restore the official OMP launcher without deleting the app or chats.
