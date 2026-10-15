#!/usr/bin/env bash
# setup_repo.sh - instructor helper for the practice repo.
#
# Usage:  scripts/setup_repo.sh <owner>/<repo> [--allow-squash] [--checks none|ci|all]
#
# What it does (safe to run again - it skips what already exists):
#   1. creates the branches develop, sit and release from main
#   2. creates the four Environments (dev, sit, pre-prod, prod), each limited to
#      ONE branch; pre-prod and prod need a reviewer (you)
#   3. creates two rulesets that protect develop/sit/release/main
#   4. allows only "merge commit" as the merge method (--allow-squash turns that off)
#
# Needs: the gh CLI, logged in as someone with admin rights on the repo, and a
# repo that already has a first commit on main. Every gh command is printed
# before it runs.
#
# --checks says which status checks the rulesets REQUIRE. A required check that
# no workflow reports blocks every PR forever, so match it to the class lab:
#   --checks none : lab 1 (repo setup; no workflow exists yet)
#   --checks ci   : lab 4 (the moment a red "test" check starts blocking the merge)
#   --checks all  : lab 5 (adds "check" from promotion-path on sit, release and main; the default)
# Re-run it at each step - it updates what exists.
#
# Merge commits only is the default: with squash merges the environment branches
# drift apart in history, so every later promotion PR re-shows old changes and can
# conflict. (The tree hash in lab 6+ survives ANY merge method; this is about clean PRs.)

set -euo pipefail

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

REPO=""
MERGE_ONLY=true
CHECKS=all
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --allow-squash) MERGE_ONLY=false ;;
    --checks) shift; CHECKS="${1:-}" ;;
    --checks=*) CHECKS="${1#--checks=}" ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) if [ -z "$REPO" ]; then REPO="$1"; else usage; fi ;;
  esac
  shift
done
case "$REPO" in */*) ;; *) echo "give the repo as <owner>/<repo>" >&2; usage ;; esac
case "$CHECKS" in none|ci|all) ;; *) echo "--checks must be none, ci or all" >&2; usage ;; esac

DEFAULT_BRANCH=main
NEW_BRANCHES="develop sit release"

# ---- small helpers ---------------------------------------------------------
say() { printf '\n== %s\n' "$*"; }

# print a command in copy-paste form (to stderr, so $(...) never captures it)
show() { { printf '+'; printf ' %q' "$@"; printf '\n'; } >&2; }

# run gh and show its output
ghx() { show gh "$@"; gh "$@"; }

# run gh quietly; only the exit status matters (used for "does it exist?")
ghq() { show gh "$@"; gh "$@" >/dev/null 2>&1; }

# gh api with a JSON body read from stdin:  gh_json METHOD PATH <<JSON ... JSON
gh_json() {
  local method="$1" path="$2" body
  body="$(cat)"
  printf '+ gh api -X %s %s --input - <<JSON\n%s\nJSON\n' "$method" "$path" "$body" >&2
  printf '%s\n' "$body" | gh api -X "$method" "$path" --input - >/dev/null
}

# ---- 0. who are we, does the repo exist? -----------------------------------
say "Checking $REPO"
ME_ID="$(ghx api user --jq .id)"
ME_LOGIN="$(ghx api user --jq .login)"
echo "authenticated as $ME_LOGIN (id $ME_ID) - this user will review pre-prod and prod"
MAIN_SHA="$(ghx api "repos/$REPO/git/ref/heads/$DEFAULT_BRANCH" --jq .object.sha)"

# ---- 1. branches -----------------------------------------------------------
say "Branches develop, sit, release (from $DEFAULT_BRANCH $MAIN_SHA)"
for b in $NEW_BRANCHES; do
  if ghq api "repos/$REPO/git/ref/heads/$b"; then
    echo "  $b already exists - skipped"
  else
    ghx api -X POST "repos/$REPO/git/refs" -f "ref=refs/heads/$b" -f "sha=$MAIN_SHA" --jq .ref
  fi
done

# ---- 2. repo settings (optional) -------------------------------------------
if [ "$MERGE_ONLY" = true ]; then
  say "Merge commits only (squash would make develop/sit/release/main drift apart in history)"
  # delete_branch_on_merge=false: otherwise GitHub offers to delete 'develop' after a develop -> sit PR.
  gh_json PATCH "repos/$REPO" <<JSON
{
  "allow_merge_commit": true,
  "allow_squash_merge": false,
  "allow_rebase_merge": false,
  "delete_branch_on_merge": false
}
JSON
fi

# ---- 3. environments -------------------------------------------------------
# environment name : the only branch allowed to deploy to it : needs a reviewer?
ENVIRONMENTS="dev:develop:no sit:sit:no pre-prod:release:yes prod:main:yes"

for spec in $ENVIRONMENTS; do
  env_name="${spec%%:*}"; rest="${spec#*:}"
  branch="${rest%%:*}"; review="${rest#*:}"
  say "Environment $env_name (deploys from $branch only; reviewer: $review)"

  if [ "$review" = yes ]; then
    reviewers="[{\"type\": \"User\", \"id\": $ME_ID}]"
  else
    reviewers="[]"
  fi

  # PUT creates the environment, or updates it if it already exists.
  # prevent_self_review=false: in a one-person org you must be allowed to approve your own deploy.
  gh_json PUT "repos/$REPO/environments/$env_name" <<JSON
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": $reviewers,
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
JSON

  # the branch rule: only this branch may deploy here
  existing="$(ghx api "repos/$REPO/environments/$env_name/deployment-branch-policies" --jq '.branch_policies[].name')"
  if printf '%s\n' "$existing" | grep -qx "$branch"; then
    echo "  branch rule '$branch' already exists - skipped"
  else
    gh_json POST "repos/$REPO/environments/$env_name/deployment-branch-policies" <<JSON
{
  "name": "$branch",
  "type": "branch"
}
JSON
  fi
done

# ---- 4. rulesets -----------------------------------------------------------
# create the ruleset with this name, or update it if it exists (so re-running is safe)
upsert_ruleset() {
  local name="$1" body id
  body="$(cat)"
  id="$(ghx api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$name\") | .id")"
  if [ -n "$id" ]; then
    echo "  ruleset '$name' exists (id $id) - updating it"
    printf '%s\n' "$body" | gh_json PUT "repos/$REPO/rulesets/$id"
  else
    printf '%s\n' "$body" | gh_json POST "repos/$REPO/rulesets"
  fi
}

if [ "$MERGE_ONLY" = true ]; then
  MERGE_METHODS='["merge"]'
else
  MERGE_METHODS='["merge", "squash", "rebase"]'
fi

CI_RULE=""
if [ "$CHECKS" = ci ] || [ "$CHECKS" = all ]; then
  # "test" = the job id in ci.yml
  CI_RULE=',
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "test" } ]
      }
    }'
fi

say "Ruleset 1: develop, sit, release and main need a pull request (and the 'test' check)"
upsert_ruleset "protect-environment-branches" <<JSON
{
  "name": "protect-environment-branches",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/develop", "refs/heads/sit", "refs/heads/release", "refs/heads/main"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": $MERGE_METHODS
      }
    }$CI_RULE
  ]
}
JSON

if [ "$CHECKS" = all ]; then
  # "check" = the job id in promotion-path.yml. Only the three PROMOTION targets need it
  # (a PR into develop may come from any branch, so it needs no promotion check).
  say "Ruleset 2: sit, release and main also need the 'check' (promotion-path) check"
  upsert_ruleset "require-promotion-path" <<JSON
{
  "name": "require-promotion-path",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/sit", "refs/heads/release", "refs/heads/main"],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "check" } ]
      }
    }
  ]
}
JSON
else
  echo
  echo "(--checks $CHECKS: the 'check' ruleset was not created. Re-run with --checks all in lab 5.)"
fi

say "Done. Look at: https://github.com/$REPO/settings/rules and /settings/environments"
