#!/usr/bin/env bash
# track-epics.sh ENV SHA
# After a deploy of SHA to ENV, labels each open epic deployed:ENV when every one
# of its slices is closed by a merged PR whose merge commit SHA contains. A label
# only moves up (development < staging < production); production closes the epic.
# Needs: a checkout with full history, GH_TOKEN with issues: write, GITHUB_REPOSITORY.
set -euo pipefail

ENV=${1:?environment}
SHA=${2:?deployed commit}
OWNER=${GITHUB_REPOSITORY%/*}
NAME=${GITHUB_REPOSITORY#*/}

rank() {
  case "$1" in
    deployed:development) echo 1 ;;
    deployed:staging) echo 2 ;;
    deployed:production) echo 3 ;;
    *) echo 0 ;;
  esac
}
target="deployed:$ENV"
target_rank=$(rank "$target")
[ "$target_rank" -gt 0 ] || { echo "unknown environment $ENV" >&2; exit 1; }

# One page is enough for the pilot; a real board pages with the cursor.
epics=$(gh api graphql -F owner="$OWNER" -F name="$NAME" -f query='
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    issues(first: 50, states: OPEN, labels: ["epic"]) {
      nodes {
        number
        labels(first: 20) { nodes { name } }
        subIssues(first: 50) {
          nodes {
            number
            state
            closedByPullRequestsReferences(first: 10, includeClosedPrs: true) {
              nodes { number merged mergeCommit { oid } }
            }
          }
        }
      }
    }
  }
}' --jq '.data.repository.issues.nodes')

count=$(jq 'length' <<<"$epics")
echo "deploy of $SHA to $ENV: $count open epic(s)"

for i in $(seq 0 $((count - 1))); do
  epic=$(jq ".[$i]" <<<"$epics")
  n=$(jq -r '.number' <<<"$epic")

  current_rank=0
  for l in $(jq -r '.labels.nodes[].name' <<<"$epic"); do
    r=$(rank "$l")
    [ "$r" -gt "$current_rank" ] && current_rank=$r
  done
  if [ "$current_rank" -ge "$target_rank" ]; then
    echo "#$n: already at or past $target"
    continue
  fi

  slices=$(jq '.subIssues.nodes' <<<"$epic")
  if [ "$(jq 'length' <<<"$slices")" -eq 0 ]; then
    echo "#$n: no slices yet"
    continue
  fi

  missing=""
  for s in $(jq -r '.[].number' <<<"$slices"); do
    slice=$(jq ".[] | select(.number == $s)" <<<"$slices")
    if [ "$(jq -r '.state' <<<"$slice")" != "CLOSED" ]; then
      missing="$missing #$s(open)"
      continue
    fi
    shipped=false
    for oid in $(jq -r '.closedByPullRequestsReferences.nodes[] | select(.merged) | .mergeCommit.oid' <<<"$slice"); do
      if git merge-base --is-ancestor "$oid" "$SHA" 2>/dev/null; then
        shipped=true
        break
      fi
    done
    [ "$shipped" = true ] || missing="$missing #$s(not in $ENV)"
  done

  if [ -n "$missing" ]; then
    echo "#$n: stays below $target; waiting on$missing"
    continue
  fi

  for l in $(jq -r '.labels.nodes[].name | select(startswith("deployed:"))' <<<"$epic"); do
    gh issue edit "$n" --remove-label "$l" >/dev/null
  done
  gh issue edit "$n" --add-label "$target" >/dev/null
  gh issue comment "$n" --body "Every slice of this epic is deployed to **$ENV** at \`${SHA:0:8}\` ([run]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID))." >/dev/null
  if [ "$ENV" = production ]; then
    gh issue close "$n" --reason completed >/dev/null
    echo "#$n: $target, closed"
  else
    echo "#$n: $target"
  fi
done
