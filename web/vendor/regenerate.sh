#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

cd "$(dirname "$0")"

printf 'node %s\n' "$(node --version)"
printf 'npm %s\n' "$(npm --version)"

npm ci
npm run build
npm run test:pkt-limit
sha256sum trystero-nostr.bundle.mjs
