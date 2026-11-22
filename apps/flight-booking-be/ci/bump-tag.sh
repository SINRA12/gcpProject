#!/usr/bin/env bash
# Writes the new image tag into the service's values file and pushes that one commit to main.
# Argo CD watches that file, so this commit is what triggers the deployment.
#
# Needs: TAG, VALUES_FILE (path from the repo root), GITOPS_REPO_URL (https), and the push
# credentials in GIT_USER / GIT_TOKEN (the Jenkins credential "github-push").
set -euo pipefail

: "${TAG:?TAG is not set}"
: "${VALUES_FILE:?VALUES_FILE is not set}"
: "${GITOPS_REPO_URL:?GITOPS_REPO_URL is not set}"
: "${GIT_USER:?GIT_USER is not set}"
: "${GIT_TOKEN:?GIT_TOKEN is not set}"

if [ "$GIT_TOKEN" = "not-set" ]; then
  echo "No GitHub token was given to Jenkins: GITHUB_TOKEN was not set when stage 6 ran." >&2
  echo "Create one (docs/runbook.md, section 9), export it, and run: ./lab.sh up delivery" >&2
  exit 1
fi

# Hand the token to git through a helper script instead of putting it in the URL or a command
# line, where it could end up in logs.
ASKPASS=$(mktemp)
trap 'rm -f "$ASKPASS"' EXIT
cat > "$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
  Username*) echo "$GIT_USER" ;;
  *) echo "$GIT_TOKEN" ;;
esac
EOF
chmod 700 "$ASKPASS"
export GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0

git config user.name "jenkins"
git config user.email "jenkins@lab.invalid"

# Start from the newest main, not from the commit that was built, so a push that landed in the
# meantime is not overwritten.
git fetch "$GITOPS_REPO_URL" main
git checkout -B tag-bump FETCH_HEAD

# (written to a new file and moved over the old one: "sed -i" differs between GNU and BSD sed)
sed "s|^  tag: .*|  tag: \"${TAG}\"|" "$VALUES_FILE" > "$VALUES_FILE.new"
mv "$VALUES_FILE.new" "$VALUES_FILE"

if git diff --quiet -- "$VALUES_FILE"; then
  echo "$VALUES_FILE already has tag $TAG: nothing to commit."
  exit 0
fi

git add "$VALUES_FILE"
git commit -m "gitops: flight-booking-be -> ${TAG}"

# Someone may have pushed since the fetch: rebase on top of it and try again
for attempt in 1 2 3; do
  if git push "$GITOPS_REPO_URL" HEAD:main; then
    echo "Pushed tag $TAG to main."
    exit 0
  fi
  git fetch "$GITOPS_REPO_URL" main
  git rebase FETCH_HEAD
done

echo "Could not push the tag commit after 3 attempts." >&2
exit 1
