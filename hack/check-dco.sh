#!/usr/bin/env bash
# Checks that every commit in a range has a "Signed-off-by" line that matches
# its author (Developer Certificate of Origin).
#
#   hack/check-dco.sh <base-ref> [<head-ref>]
set -euo pipefail

base=${1:?usage: $0 <base-ref> [<head-ref>]}
head=${2:-HEAD}
errors=0
for commit in $(git rev-list --no-merges "$base..$head"); do
  author=$(git log -1 --format='%an <%ae>' "$commit")
  if git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$commit" | grep -qxF "$author"; then
    echo "ok    $(git log -1 --format='%h %s' "$commit")"
  else
    echo "FAIL  $(git log -1 --format='%h %s' "$commit"): no 'Signed-off-by: $author'"
    errors=$((errors + 1))
  fi
done
if [[ $errors -gt 0 ]]; then
  echo "ERROR: $errors commit(s) without a matching Signed-off-by line. Use 'git commit -s'." >&2
  exit 1
fi
echo "All commits are signed off."
