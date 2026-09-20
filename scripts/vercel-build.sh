#!/usr/bin/env bash
set -euo pipefail

flutter_root="${VERCEL_FLUTTER_ROOT:-$PWD/.vercel/flutter}"
if ! command -v flutter >/dev/null 2>&1 && [ -x "$flutter_root/bin/flutter" ]; then
  export PATH="$flutter_root/bin:$PATH"
fi
git config --global --add safe.directory "$flutter_root" >/dev/null 2>&1 || true

deployment_ref="${VERCEL_GIT_COMMIT_REF:-$(git branch --show-current 2>/dev/null || true)}"
if [ "${VERCEL_ENV:-}" = "production" ] && [ "$deployment_ref" != "trunk" ]; then
  echo "Refusing production build from '$deployment_ref'; deploy ThesisForge only from trunk." >&2
  exit 1
fi

flutter --version
flutter pub get
npm run build
