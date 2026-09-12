# Agent installation UX check

Checked on September 13, 2026, after narrowing installation to local source builds.

The guide is usable for a local coding agent, but installation should not be presented as hands-off. Developer tools may require user action, provider sign-in requires the user, and dependency downloads need visible progress and bounded retries.

## Test scope

This was an agent-style walkthrough on an existing Apple Silicon development Mac running macOS 26.6.2. It was not an independent agent trial, clean-Mac test, Intel test, or new-account sign-in test. The successful app build reused existing runtime downloads and dependency caches.

| Check | Result | Evidence or limit |
| --- | --- | --- |
| Fresh public repository clone | Passed | A separate checkout was created successfully. |
| Update isolated checkout to the new guide revision | Blocked | GitHub fetch stalled; a second attempt was stopped after 45 seconds. |
| Fully fresh runtime and app build | Not verified | The isolated checkout update blocked this path. |
| Local app build | Passed | Release build completed with existing dependencies. |
| App installation and bundle integrity | Passed | Installed app passed `codesign --verify --deep --strict`. |
| Menu-bar app and footer | Passed | App opened; the saved hidden-footer preference was handled through its floating control. |
| Rename and restore name | Passed | The footer updated after renaming and returned to the OMP name after reset. |
| Automated regression tests | Passed | Six tests, including persistent names and full-history ordering. |
| Guide shell examples | Passed | All five shell blocks passed zsh syntax checks. |
| Provider sign-in and first model response | Not tested | No credentials were entered and no model prompt was sent. |
| Optional terminal sync on a fresh profile | Not tested | Existing terminal configuration and credentials were left untouched. |

## Improvements made

- Kept one installation route: build locally from source.
- Made terminal integration optional. Users who only need Mini Chat can skip PATH and launcher setup.
- Added a concrete user-writable installation fallback and reused the actual app path for later commands.
- Bundled the integration installer so optional setup does not depend on remembering the source checkout's location.
- Added bounded network retry guidance and instructions to report the failed stage.
- Explained that an empty history is valid and that More requires additional chats.
- Explained how to find a footer hidden by an existing installation's preference.
- Distinguished a successful copy, verified app launch, and readiness to chat after sign-in.

## Next UX validation

Run the guide with a local agent on a Mac without cached dependencies. Observe prerequisite setup, build time, recovery from a failed download, footer discovery, and the handoff to provider sign-in. Record every user question and every point where the agent reports completion too early. That is the remaining evidence needed before calling this a verified first-time installation experience.
