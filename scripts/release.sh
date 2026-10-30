#!/bin/bash
# Usage: commit your work with a conventional message, then run ./scripts/release.sh
# Version = 1.0.<commit count>, so it auto-increments with every commit.
set -e

cd "$(dirname "$0")/.."

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "error: release from main (currently on $BRANCH)" >&2
    exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "error: uncommitted changes. Commit them first (e.g. git commit -m 'feat: ...')" >&2
    exit 1
fi

# CI commits cask updates to main after each release; stay in sync with it
git pull --rebase --quiet origin main

# The bump commit adds one more commit, so count it in the version
COMMIT_COUNT=$(( $(git rev-list --count HEAD) + 1 ))
VERSION="1.0.${COMMIT_COUNT}"

if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
    echo "error: tag v${VERSION} already exists" >&2
    exit 1
fi

echo "==> Version: $VERSION"

sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = ${VERSION};/g" LyricBar.xcodeproj/project.pbxproj
git add LyricBar.xcodeproj/project.pbxproj
git commit -m "chore: bump version to ${VERSION}"

git tag "v${VERSION}"

echo "==> Pushing to origin..."
git push origin main
git push origin "v${VERSION}"

echo ""
echo "==> Done: v${VERSION} released!"
echo "    Watch: https://github.com/rigelra15/LyricBar/actions"
