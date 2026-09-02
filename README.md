# OMP Mini Chat

An always-on-top macOS footer for [Oh My Pi](https://github.com/can1357/oh-my-pi), with resizable chat popups and automatic encrypted synchronization with active terminal sessions.

## Use

```sh
./Scripts/build-synced-omp.sh
./Scripts/build-app.sh
./Scripts/install-integration.sh
open "./outputs/OMP Mini Chat.app"
```

Requires macOS 13+. Use `omp` normally; active terminal sessions appear and sync automatically. Use `omp --stock` for untouched official OMP, or run `./Scripts/uninstall-integration.sh` to restore it as the default.
