#!/usr/bin/env bash
#
# push.sh — stage, commit, and push everything in one step.
#
#   ./push.sh "Add rest timer Live Activity"
#   ./push.sh                                  # prompts for the message
#
# Deliberately shows you what changed before committing. A script that silently
# commits everything is how a stray file or a secret ends up in public history.

set -euo pipefail

# Run from the repo root regardless of where it was invoked.
cd "$(dirname "$0")"

if [[ ! -d .git ]]; then
  echo "Not a git repository: $(pwd)"
  exit 1
fi

if [[ -z "$(git status --porcelain)" ]]; then
  echo "Nothing to commit — working tree is clean."
  exit 0
fi

echo "Changes to be committed:"
echo
git status --short
echo

MESSAGE="${*:-}"

if [[ -z "$MESSAGE" ]]; then
  read -rp "Commit message: " MESSAGE
fi

if [[ -z "$MESSAGE" ]]; then
  echo "Aborted — commit message was empty."
  exit 1
fi

git add -A
git commit -m "$MESSAGE"

# --- Push ---
# Sets the upstream on first push so later runs are a bare `git push`.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if git rev-parse --abbrev-ref "@{upstream}" >/dev/null 2>&1; then
  # Pick up anything committed elsewhere first — editing a file directly on
  # github.com leaves this machine behind, and the push would just be rejected.
  # Rebase rather than merge so the history stays a straight line instead of
  # collecting "Merge branch 'main'" commits nobody wants to read.
  echo "Checking for remote changes..."
  if ! git pull --rebase --autostash; then
    echo
    echo "Pull failed — probably a conflict. Resolve it, then run:"
    echo "  git rebase --continue && git push"
    exit 1
  fi
  git push
else
  git push -u origin "$BRANCH"
fi

echo
echo "Pushed to $BRANCH."
git log --oneline -1
