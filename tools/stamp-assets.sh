#!/usr/bin/env bash
# Stamp shared asset URLs with a content hash so browsers never pair a new page
# with a cached stylesheet, script or icon sprite (GitHub Pages sends max-age=600).
# Run from anywhere after changing anything in assets/, then commit the result.
set -euo pipefail

cd "$(dirname "$0")/.."

hash=$(cat assets/site.css assets/site.js assets/icons.svg | shasum -a 256 | cut -c1-10)

pages=(index.html 404.html)
for page in */index.html; do
  pages+=("$page")
done

for page in "${pages[@]}"; do
  perl -pi -e 's{(site\.css|site\.js|icons\.svg)(\?v=[0-9a-f]+)?}{$1?v='"$hash"'}g' "$page"
done

echo "assets stamped with v=$hash in: ${pages[*]}"
