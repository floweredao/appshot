# Contributing

Appshot is a macOS menu bar app written in Swift. The app target lives in `App/`; everything that can be tested without a window server lives in the `AppshotCore` package under `Packages/AppshotCore/`.

## Getting set up

You need macOS 15 or later, Xcode 16 or later, and XcodeGen.

```sh
brew install xcodegen
./scripts/build.sh                                # Release build
swift test --package-path Packages/AppshotCore    # unit tests
```

Without an Apple Development certificate the build is signed ad hoc, which is enough to run it. `./scripts/build.sh --install` replaces `/Applications/Appshot.app` with your build. [Build from source](README.md#build-from-source) explains what an ad-hoc signature costs: macOS asks for Screen Recording and Accessibility again after every rebuild.

The Xcode project is generated from `project.yml` and is not checked in, so change `project.yml`, not the generated project.

## Where things go

| Path | What |
| --- | --- |
| `App/` | SwiftUI app: capture panel, editor, settings, Accessibility and Discord work. |
| `Packages/AppshotCore/Sources` | Logic with no UI: config, destinations, text composition, send targets, updates, capture edits. |
| `Packages/AppshotCore/Tests` | Swift Testing suites. New behavior goes here whenever it can. |
| `Resources/Localizable.xcstrings` | Every user-visible string, in English and Korean. |
| `docs/` | Screenshots, rendered from the built-in demo scenes. |

## House rules

- **Two languages.** Every string a user can see goes through `Resources/Localizable.xcstrings` with both the English and the Korean translation in the same change. No Korean literals in `App/`.
- **No personal values.** Channel IDs, local paths, bot aliases, and team IDs belong in `~/Library/Application Support/Appshot/config.json` or the git-ignored `Config/Local.xcconfig`, never in the repository. Screenshots come from the demo scenes (`--render … --scene …`), never from a real capture.
- **A fix comes with a test.** `swift test --package-path Packages/AppshotCore` must pass, and a bug fix should come with a test that fails without it. CI runs the same command on a macOS runner for every pull request.
- **Run the checks before you push.**

  ```sh
  swift test --package-path Packages/AppshotCore
  sh scripts/prepush-check.sh      # gitleaks plus the personal-data scan
  ```

  To have git run the second one for you:

  ```sh
  ln -s ../../scripts/prepush-check.sh .git/hooks/pre-push
  ```

## Pull requests

- One concern per pull request. Title it `type(scope): what changed`, using `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `build`, `ci`, or `perf`.
- Say what changed, why, and how you checked it: the commands you ran and what they printed.
- Changes to update verification, to signing, or to anything that decides what the app runs need a maintainer's review before they are merged.

## Reporting a bug

Open an issue with what you did, what you expected, what happened, and your macOS and Xcode versions. For a capture problem, the app that owned the window and the method the text came from help most; `meta.json` in the capture folder records the method under `text.method`.
