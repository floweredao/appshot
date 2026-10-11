# Appshot agent notes

## Rules

- **Two languages, always.** Every user-visible string (menu bar menu, capture panel, settings, permission guidance, alerts, errors) goes through `Resources/Localizable.xcstrings` with English (development language) and Korean. Use `Text("…")` / `String(localized: "…")` keys and add both translations in the same change. The app follows the macOS system language: Korean on a Korean system, English otherwise. No hard-coded Korean in `App/` (`grep -n '[가-힣]' App/*.swift` must print nothing).
- **No personal values in the repo.** Channel IDs, local paths, bot aliases, and signing team IDs live in `~/Library/Application Support/Appshot/config.json` or the git-ignored `Config/Local.xcconfig`. Screenshots in `docs/` use the built-in demo scene (`--render … --scene typing|picker`), never a real capture.
- **Before every push** run `scripts/prepush-check.sh` (installed as `.git/hooks/pre-push`): gitleaks plus the email / home-path / snowflake-ID / image / personal-pattern scan. `docs/*.png` is the only allowed image path.
- **Verification without UI automation.** Do not use XCUITest or UI scripting on the owner's Mac. Use `swift test --package-path Packages/AppshotCore`, `--appshot-now` for real captures, and `--render` for offscreen screenshots.

## Commands

```sh
./scripts/build.sh --install                          # signed Release build -> /Applications
swift test --package-path Packages/AppshotCore        # unit tests
swift scripts/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset
open -n -W -a Appshot --args --render /tmp/p.png --scene picker --dark -AppleLanguages '(ko)'
```
