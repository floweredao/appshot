# Releasing Appshot

The in-app updater reads `GET https://api.github.com/repos/floweredao/appshot/releases/latest` and installs a release only when all of these hold, so every release must keep them true:

| Requirement | Why |
| --- | --- |
| The tag is a version such as `v0.4.0`, higher than the last one, and the release is neither a draft nor a prerelease. | Appshot compares the tag with its own `CFBundleShortVersionString`. |
| The release has an asset named exactly `Appshot.zip` containing `Appshot.app` at the top level (`ditto -c -k --keepParent`). | The updater looks for that asset name and that path. |
| `CFBundleShortVersionString` inside the app equals the tag without `v`. | A download that is not newer is refused. |
| The app is signed with the same Apple Development certificate and team as the previous release, bundle ID `com.floweredao.appshot`. | The new app must satisfy the running app's designated requirement; this also keeps the Screen Recording and Accessibility permissions. |

GitHub computes the asset's SHA-256 digest itself when the file is uploaded; there is no key or checksum file to manage.

## Steps

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml`, then commit (`chore: bump version to X.Y.Z`).
2. `swift test --package-path Packages/AppshotCore` and `scripts/prepush-check.sh`.
3. `./scripts/build.sh --install`, then `ditto -c -k --keepParent .work/DerivedData/Build/Products/Release/Appshot.app .work/Appshot.zip`.
4. Check the zip: `codesign --verify --strict` on the unpacked app, and that `Info.plist` shows the new version.
5. Push, then `gh release create vX.Y.Z .work/Appshot.zip --title "Appshot X.Y.Z" --notes-file <notes>`.
6. Confirm the updater sees it from an older build: `Appshot.app/Contents/MacOS/Appshot --check-update` prints `update available`.

## Headless checks

```sh
Appshot.app/Contents/MacOS/Appshot --check-update                                  # ask GitHub; prints up to date or the available version
Appshot.app/Contents/MacOS/Appshot --install-update [--no-relaunch]                # verify, replace this copy after it exits, and reopen it
Appshot.app/Contents/MacOS/Appshot --verify-update <zip> --sha256 <hex>            # run every check on a local zip without installing
```

The replacement step logs to `~/Library/Logs/Appshot/update.log`.
