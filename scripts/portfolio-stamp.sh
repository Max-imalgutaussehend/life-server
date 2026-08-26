#!/usr/bin/env bash
# =============================================================================
# portfolio-stamp.sh — stamp style.css with its content hash. (M12)
# =============================================================================
#
# WHY THIS EXISTS
#   Cloudflare caches static assets at the edge and honours the origin's
#   Cache-Control. Even at max-age=300 there is a window where the HTML is new
#   and the stylesheet is still the old one — and that combination looks
#   exactly like "the deploy did nothing", because the page renders with stale
#   rules against fresh markup.
#
#   That is not hypothetical: it happened twice while building this site.
#   Measured the second time — `cf-cache-status: HIT, age: 614` on style.css
#   while the HTML came back DYNAMIC and current.
#
#   Appending the file's own hash to the URL makes the problem structurally
#   impossible: change the CSS, the URL changes, and no cache can serve the
#   old bytes under the new name.
#
# RUN IT BEFORE DEPLOYING, whenever style.css changed:
#   ./scripts/portfolio-stamp.sh && ./scripts/deploy.sh
#
# It is idempotent — running it on unchanged CSS rewrites the same value.
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="$REPO/compose/portfolio/site"
CSS="$SITE/style.css"
HTML="$SITE/index.html"

for f in "$CSS" "$HTML"; do
	[[ -f "$f" ]] || { echo "error: $f missing" >&2; exit 1; }
done

# md5 on macOS, md5sum on Linux — this runs from either.
if command -v md5 >/dev/null 2>&1; then
	HASH="$(md5 -q "$CSS" | cut -c1-8)"
else
	HASH="$(md5sum "$CSS" | cut -c1-8)"
fi

python3 - "$HTML" "$HASH" <<'PY'
import re, sys
path, h = sys.argv[1], sys.argv[2]
src = open(path).read()
new, n = re.subn(r'href="/style\.css(?:\?v=[0-9a-f]+)?"', f'href="/style.css?v={h}"', src)
if n == 0:
    sys.exit("error: no stylesheet link found in " + path)
if new != src:
    open(path, 'w').write(new)
    print(f"stamped style.css?v={h}")
else:
    print(f"already current (v={h})")
PY
