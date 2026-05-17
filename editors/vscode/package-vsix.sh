#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")"

if command -v npx >/dev/null 2>&1; then
  npx --yes @vscode/vsce package
elif command -v vsce >/dev/null 2>&1; then
  vsce package
else
  echo "error: expected npx or vsce on PATH" >&2
  echo "install Node.js/npm, or install vsce with: npm install -g @vscode/vsce" >&2
  exit 1
fi
