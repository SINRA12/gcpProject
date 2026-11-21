#!/usr/bin/env bash
# Installs terraform into ~/bin on Google Cloud Shell. Cloud Shell only ships an
# install stub, and anything outside $HOME is wiped when the VM recycles, so the
# binary goes in your home directory, which persists. Safe to run again.
#   ./scripts/install-terraform-cloudshell.sh            install the latest version
#   TF_VERSION=1.9.8 ./scripts/install-terraform-cloudshell.sh   pin a version
set -euo pipefail

BIN="$HOME/bin"
mkdir -p "$BIN"

VERSION="${TF_VERSION:-$(curl -fsS https://checkpoint-api.hashicorp.com/v1/check/terraform \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["current_version"])')}"

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

if [[ -x "$BIN/terraform" ]] && "$BIN/terraform" -version | head -1 | grep -q "v$VERSION\$"; then
  echo "terraform $VERSION is already installed in $BIN"
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/tf.zip" "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_${ARCH}.zip"
  unzip -q -o "$TMP/tf.zip" -d "$BIN"
  echo "Installed terraform $VERSION to $BIN"
fi

# Put ~/bin first so it wins over Cloud Shell's install stub
if ! grep -q 'HOME/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH=$HOME/bin:$PATH' >> "$HOME/.bashrc"
  echo "Added ~/bin to PATH in ~/.bashrc"
fi

echo
echo "Run this once in the current shell (new shells pick it up automatically):"
echo "  export PATH=\$HOME/bin:\$PATH && hash -r && terraform -version"
