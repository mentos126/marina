#!/bin/bash
# Builds, notarizes, and publishes the version already committed in Version.swift.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(git -C "$ROOT" show HEAD:Sources/MarinaCore/Version.swift | grep -o '"[0-9][^"]*"' | tr -d '"')"
EXPECTED_VERSION="${1:-$VERSION}"
TAG="v$VERSION"
# The target repository is read from the git remote, never hardcoded here.
REPO="$(git -C "$ROOT" remote get-url origin \
  | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')"

if [ "$EXPECTED_VERSION" != "$VERSION" ]; then
  echo "Version.swift contains $VERSION, not $EXPECTED_VERSION." >&2
  exit 1
fi

BRANCH="$(git -C "$ROOT" branch --show-current)"
LOCAL_SHA="$(git -C "$ROOT" rev-parse HEAD)"
REMOTE_SHA="$(git -C "$ROOT" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  echo "Push $BRANCH before publishing $TAG." >&2
  exit 1
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists." >&2
  exit 1
fi

RELEASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/marina-release.XXXXXX")"
SOURCE_DIR="$RELEASE_DIR/source"
mkdir -p "$SOURCE_DIR"
trap 'trash "$RELEASE_DIR" >/dev/null 2>&1 || true' EXIT

# Build exactly the pushed commit. Local edits in the working tree are never
# stashed, copied into the archive, or otherwise disturbed.
git -C "$ROOT" archive HEAD | tar -x -C "$SOURCE_DIR"

"$SOURCE_DIR/build.sh" --release

gh release create "$TAG" \
  "$SOURCE_DIR/dist/Marina-macOS.zip#Marina for macOS" \
  --repo "$REPO" \
  --target "$LOCAL_SHA" \
  --title "Marina $VERSION" \
  --generate-notes

mkdir -p "$ROOT/dist"
cp "$SOURCE_DIR/dist/Marina-macOS.zip" "$ROOT/dist/Marina-macOS.zip"

gh release view "$TAG" --repo "$REPO" --json tagName,url,assets
