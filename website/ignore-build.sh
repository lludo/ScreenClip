#!/bin/sh
# Exit 0 skips the Vercel build. Exit 1 builds.
# Vercel runs ignoreCommand from the project Root Directory (website/).

cd "$(dirname "$0")" || exit 1

has_commit() {
  git cat-file -e "$1^{commit}" >/dev/null 2>&1
}

# Skip when website/ is unchanged since $1. Build when it changed or the diff failed.
compare_site() {
  if git diff --quiet "$1" HEAD -- .; then
    echo "ignore-build: skip, website unchanged since $1"
    exit 0
  fi
  echo "ignore-build: build, website changed since $1"
  exit 1
}

prev="${VERCEL_GIT_PREVIOUS_SHA:-}"
if [ -n "$prev" ]; then
  if ! has_commit "$prev"; then
    echo "ignore-build: fetching $prev"
    git fetch --depth=1 origin "$prev" || exit 1
  fi
  has_commit "$prev" || exit 1
  compare_site "$prev"
fi

# First deployment of a branch: there is no previous successful deploy.
# Compare a preview with main. The first deploy of main itself builds.
ref="${VERCEL_GIT_COMMIT_REF:-}"
if [ -z "$ref" ] || [ "$ref" = "main" ]; then
  echo "ignore-build: build, no previous deploy on ${ref:-unknown ref}"
  exit 1
fi

echo "ignore-build: no previous deploy, comparing with main"
git fetch --depth=1 origin main || exit 1
compare_site FETCH_HEAD
