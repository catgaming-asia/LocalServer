#!/bin/zsh
# Packages a Local Server release for the public folder on Cloudflare R2.
#   build/release.command [patch|minor|major|<x.y.z>] [--notes "<text>"]
# Bumps VERSION, rebuilds build/LocalServer.app, commits "Release v<x>" (VERSION + the app), tags v<x> (local),
# zips the app + writes latest.json into build/release/ (not committed). No API, no token: upload to R2 by hand.
# Asks before pushing.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

usage() {
    echo "Usage: build/release.command [patch|minor|major|<x.y.z>] [--notes \"<text>\"]" >&2
    exit 2
}

BUMP="patch"
NOTES=""
HAVE_NOTES=0
while (( $# > 0 )); do
    case "$1" in
        --notes) (( $# >= 2 )) || usage; NOTES="$2"; HAVE_NOTES=1; shift 2 ;;
        --notes=*) NOTES="${1#--notes=}"; HAVE_NOTES=1; shift ;;
        -h|--help) usage ;;
        patch|minor|major) BUMP="$1"; shift ;;
        [0-9]*.[0-9]*.[0-9]*) BUMP="$1"; shift ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

# --- git ---
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Uncommitted changes. Commit or discard them first." >&2
    exit 1
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    echo "Release from main only (current branch: $BRANCH)." >&2
    exit 1
fi

# --- New version ---
CURRENT="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$CURRENT" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "VERSION must be x.y.z (found: $CURRENT)." >&2
    exit 1
fi
parts=("${(@s:.:)CURRENT}")
MAJOR=${parts[1]} MINOR=${parts[2]} PATCH=${parts[3]}
case "$BUMP" in
    patch) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    minor) NEW="$MAJOR.$((MINOR + 1)).0" ;;
    major) NEW="$((MAJOR + 1)).0.0" ;;
    *)
        if [[ ! "$BUMP" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
            echo "Version must be x.y.z (got: $BUMP)." >&2
            exit 1
        fi
        NEW="$BUMP"
        ;;
esac
TAG="v$NEW"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi

# Notes: --notes, or the commits since the previous tag.
PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if (( ! HAVE_NOTES )); then
    if [[ -n "$PREV_TAG" ]]; then
        NOTES="$(git log --no-merges --pretty='- %s' "$PREV_TAG..HEAD")"
    else
        NOTES="$(git log --no-merges --pretty='- %s' -n 30)"
    fi
    [[ -n "$NOTES" ]] || NOTES="- Maintenance release"
fi

# --- Build, commit + tag (local) ---
echo "$NEW" > VERSION
# The Release commit is counted in CFBundleVersion: build after bumping, the count is HEAD + 1.
git add VERSION
git commit -q -m "Release $TAG"
bash "${0:A:h}/build-app.command"
APP="$ROOT/build/LocalServer.app"
git add -A build/LocalServer.app
git commit -q --amend --no-edit
git tag -a "$TAG" -m "Local Server $NEW"
echo "Committed and tagged $TAG (local)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

# --- Package ---
OUT="$ROOT/build/release"
mkdir -p "$OUT"
# Keep only the latest.
rm -f -- "$OUT"/LocalServer-*.zip(N) "$OUT/latest.json"
FILE="LocalServer-$NEW.zip"
ZIP="$OUT/$FILE"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
SIZE="$(stat -f %z "$ZIP")"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

NEW="$NEW" BUILD_NUMBER="$BUILD_NUMBER" DATE="$DATE" NOTES="$NOTES" FILE="$FILE" SIZE="$SIZE" SHA="$SHA" perl -MJSON::PP -e '
    print JSON::PP->new->canonical->pretty->encode({
        version => $ENV{NEW}, build => 0 + $ENV{BUILD_NUMBER}, date => $ENV{DATE}, notes => $ENV{NOTES},
        file => $ENV{FILE}, size => 0 + $ENV{SIZE}, sha256 => $ENV{SHA},
    });
' > "$OUT/latest.json"

echo
echo "Version:  $NEW build $BUILD_NUMBER (previous $CURRENT${PREV_TAG:+, last tag $PREV_TAG})"
echo "Zip:      $ZIP ($SIZE bytes)"
echo "Manifest: $OUT/latest.json"
echo "SHA-256:  $SHA"
echo "Notes:"
print -r -- "$NOTES" | sed 's/^/  /'
echo
echo "Upload $FILE then latest.json to LocalServer/release/ in the R2 bucket (https://data.catgaming.asia/LocalServer/release/), then purge the cache for latest.json."
echo

printf 'Push commit and tag to origin? [y/N] ' > /dev/tty
read -r ANSWER < /dev/tty || ANSWER=""
if [[ "$ANSWER" == [yY] || "$ANSWER" == [yY][eE][sS] ]]; then
    git push origin main "$TAG"
else
    echo "Not pushed. Later: git push origin main $TAG"
fi
