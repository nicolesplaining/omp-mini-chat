# Codex Mini Chat

A small, always-on-top macOS chat footer for Codex. It shows your recent tasks, supports multiple popups, and continues the same synced task without creating branches.

## Use

Requires macOS 13 or newer and Codex signed in.

1. Run `swift build -c release`.
2. Launch `.build/release/MiniChat`.
3. Allow Accessibility access when prompted.
4. Keep Codex open, select a task tab, and type. Mini Chat sends through Codex so the original task, project, permissions, and Git access stay in sync.

Select message text and press **Command-C**, or use a message’s copy button. Standard **Command-V**, **Command-X**, and **Command-A** shortcuts work in the composer. Press **Control–Option–Space** to show or hide the popups.
