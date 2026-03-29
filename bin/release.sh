#!/usr/bin/env bash
# LakeTS Release Automation Script
#
# Usage:
#   ./bin/release.sh [patch|minor|major]
#   ./bin/release.sh --dry-run [patch|minor|major]
#
# Steps:
#   1. Verify working directory is clean
#   2. Detect unreleased commits since last tag
#   3. Bump version (patch by default)
#   4. Update CHANGELOG.md ([Unreleased] -> [vX.Y.Z])
#   5. Update VERSION file
#   6. Commit changelog + version bump
#   7. Create and push git tag (triggers GitHub Actions release workflow)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[release]${NC} $*"; }
success() { echo -e "${GREEN}[release]${NC} $*"; }
warn()    { echo -e "${YELLOW}[release]${NC} $*"; }
die()     { echo -e "${RED}[release] ERROR:${NC} $*" >&2; exit 1; }

DRY_RUN=false
BUMP_TYPE="patch"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    patch|minor|major) BUMP_TYPE="$arg" ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [patch|minor|major]"
      echo "  patch  (default) — increment Z in X.Y.Z"
      echo "  minor            — increment Y in X.Y.Z, reset Z to 0"
      echo "  major            — increment X in X.Y.Z, reset Y and Z to 0"
      echo "  --dry-run        — show what would happen, make no changes"
      exit 0
      ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "Not inside a git repository."
cd "$REPO_ROOT"

command -v git  >/dev/null || die "git not found."
command -v sed  >/dev/null || die "sed not found."
command -v awk  >/dev/null || die "awk not found."

if [[ -n "$(git status --porcelain)" ]]; then
  die "Working directory is not clean. Commit or stash changes first."
fi

VERSION_FILE="$REPO_ROOT/VERSION"
[[ -f "$VERSION_FILE" ]] || die "VERSION file not found at $VERSION_FILE"
CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

if ! echo "$CURRENT_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  die "VERSION file contains invalid semver: '$CURRENT_VERSION'"
fi

MAJOR="$(echo "$CURRENT_VERSION" | cut -d. -f1)"
MINOR="$(echo "$CURRENT_VERSION" | cut -d. -f2)"
PATCH="$(echo "$CURRENT_VERSION" | cut -d. -f3)"

case "$BUMP_TYPE" in
  patch) NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  minor) NEW_VERSION="$MAJOR.$((MINOR + 1)).0" ;;
  major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
esac

info "Current version : v${CURRENT_VERSION}"
info "Bump type       : ${BUMP_TYPE}"
info "New version     : v${NEW_VERSION}"

LAST_TAG="v${CURRENT_VERSION}"
if git rev-parse "$LAST_TAG" >/dev/null 2>&1; then
  UNRELEASED_COMMITS="$(git log "${LAST_TAG}..HEAD" --oneline)"
else
  warn "Tag $LAST_TAG not found — treating all commits as unreleased."
  UNRELEASED_COMMITS="$(git log --oneline)"
fi

if [[ -z "$UNRELEASED_COMMITS" ]]; then
  warn "No unreleased commits found since $LAST_TAG. Nothing to release."
  exit 0
fi

COMMIT_COUNT="$(echo "$UNRELEASED_COMMITS" | wc -l | tr -d ' ')"
info "Unreleased commits since ${LAST_TAG} (${COMMIT_COUNT}):"
echo "$UNRELEASED_COMMITS" | sed 's/^/  /'

CHANGELOG="$REPO_ROOT/CHANGELOG.md"
[[ -f "$CHANGELOG" ]] || die "CHANGELOG.md not found at $CHANGELOG"

if ! grep -q '## \[Unreleased\]' "$CHANGELOG"; then
  die "CHANGELOG.md does not contain a '## [Unreleased]' section."
fi

UNRELEASED_CONTENT="$(awk '/^## \[Unreleased\]/{found=1; next} found && /^## /{exit} found{print}' "$CHANGELOG")"
UNRELEASED_TRIMMED="$(echo "$UNRELEASED_CONTENT" | sed '/^[[:space:]]*$/d')"

if [[ -z "$UNRELEASED_TRIMMED" ]]; then
  warn "## [Unreleased] section is empty — nothing to document in this release."
fi

if $DRY_RUN; then
  warn "DRY RUN — no changes made."
  info "Would release v${NEW_VERSION} with tag v${NEW_VERSION}"
  exit 0
fi

RELEASE_DATE="$(date -u '+%Y-%m-%d')"

info "Updating CHANGELOG.md ..."
# Build replacement: insert fresh [Unreleased] block before the versioned heading
TEMP_CHANGELOG="$(mktemp)"
awk -v new_ver="v${NEW_VERSION}" -v rel_date="${RELEASE_DATE}" '
  /^## \[Unreleased\]/ {
    print "## [Unreleased]"
    print ""
    print "## [" new_ver "] - " rel_date
    next
  }
  { print }
' "$CHANGELOG" > "$TEMP_CHANGELOG"
mv "$TEMP_CHANGELOG" "$CHANGELOG"
success "CHANGELOG.md updated."

info "Updating VERSION to ${NEW_VERSION} ..."
echo "$NEW_VERSION" > "$VERSION_FILE"
success "VERSION updated."

info "Committing version bump ..."
git add "$CHANGELOG" "$VERSION_FILE"
git commit -m "chore: release v${NEW_VERSION}

- Bumped VERSION from ${CURRENT_VERSION} to ${NEW_VERSION}
- Moved [Unreleased] changelog entries to [v${NEW_VERSION}]

Co-Authored-By: Paperclip <noreply@paperclip.ing>"
success "Committed version bump."

info "Creating tag v${NEW_VERSION} ..."
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"
success "Tag v${NEW_VERSION} created."

info "Pushing commit and tag to origin ..."
git push origin HEAD
git push origin "v${NEW_VERSION}"
success "Pushed. GitHub Actions release workflow will now build and publish v${NEW_VERSION}."

echo ""
success "Release v${NEW_VERSION} complete!"
