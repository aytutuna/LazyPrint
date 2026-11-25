#!/usr/bin/env bash
# The repository is public, so a build left as a run artifact can be downloaded by anyone signed in to GitHub.
# Only screenshots and test results are uploaded, and the two store uploads refuse a commit without a green CI run.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
for file in .github/workflows/*.yml; do
  while read -r name; do
    case "$name" in
      mac-screens | ios-screenshots* | ios-tests-xcresult*) ;;
      *) echo "$file uploads an artifact named $name"; fail=1 ;;
    esac
  done < <(awk '/uses: actions\/upload-artifact/ { found = 1; next } found && /^ *name:/ { print $2; found = 0 }' "$file")
done

for file in .github/workflows/testflight.yml .github/workflows/macappstore.yml; do
  grep -q 'Check that CI passed' "$file" || { echo "$file does not check the CI run of the commit"; fail=1; }
done

[ ! -e .github/workflows/release.yml ] || { echo "release.yml is back"; fail=1; }
exit $fail
