#!/bin/sh
# Pre-push gate: secrets (gitleaks) plus personal-data scan over tracked files and unpushed commits and their identities.
# Personal strings to block live outside the repo, one per line, in $APPSHOT_PRIVACY_PATTERNS
# (default: .work/privacy-patterns.txt, which is git-ignored).
set -eu
cd "$(git rev-parse --show-toplevel)"
fail=0
report() { echo "privacy: $*" >&2; fail=1; }

gitleaks git --no-banner --redact . >/dev/null 2>.work-gitleaks.log || {
  cat .work-gitleaks.log >&2
  report "gitleaks found secrets in history"
}
gitleaks dir --no-banner --redact . >/dev/null 2>>.work-gitleaks.log || {
  cat .work-gitleaks.log >&2
  report "gitleaks found secrets in the working tree"
}
rm -f .work-gitleaks.log

images=$(git ls-files | grep -Ei '\.(png|jpe?g|heic|gif|tiff?|mov|mp4)$' | grep -Ev '^(docs/[^/]+\.png|Resources/Assets\.xcassets/AppIcon\.appiconset/[^/]+\.png)$' || true)
[ -z "$images" ] || report "images outside docs/ and the app icon: $images"

# Commits already on a remote are public and cannot be rewritten, so only commits not yet pushed are
# scanned (all of history when there is no remote). Tracked files are always scanned in full.
history=$(git log --all --not --remotes -p --format='%an <%ae> %cn <%ce>%n%B' 2>/dev/null; git ls-files -z | xargs -0 cat 2>/dev/null)

# Email addresses other than GitHub noreply (including GitHub's own committer identity on merge commits).
emails=$(printf '%s' "$history" | grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | grep -Ev '(users\.noreply\.github\.com|^noreply@github\.com)$' | grep -Ev '@[0-9]x\.(png|jpe?g|pdf)$' | sort -u || true)
[ -z "$emails" ] || report "email addresses: $emails"

# Absolute home paths (a placeholder like /Users/<you> is allowed).
paths=$(printf '%s' "$history" | grep -Eo '/(Users|home)/[A-Za-z0-9._-]+' | sort -u || true)
[ -z "$paths" ] || report "local home paths: $paths"

# Discord-style snowflake ids (17-20 digits).
ids=$(printf '%s' "$history" | grep -Eo '(^|[^0-9])[0-9]{17,20}([^0-9]|$)' | tr -cd '0-9\n' | sort -u || true)
[ -z "$ids" ] || report "numeric ids that look like channel/user ids: $ids"

patterns="${APPSHOT_PRIVACY_PATTERNS:-.work/privacy-patterns.txt}"
if [ -f "$patterns" ]; then
  hits=$(printf '%s' "$history" | grep -Fio -f "$patterns" | sort -u || true)
  [ -z "$hits" ] || report "personal strings from $patterns: $hits"
else
  echo "privacy: note: $patterns not found; personal-string scan skipped" >&2
fi

[ "$fail" -eq 0 ] && echo "prepush-check: clean"
exit "$fail"
