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
PDF="$SITE/cv.pdf"
HTML="$SITE/index.html"
# The German page links the same assets and needs the same stamps.
HTML_DE="$SITE/de/index.html"

for f in "$CSS" "$PDF" "$HTML" "$HTML_DE"; do
	[[ -f "$f" ]] || { echo "error: $f missing" >&2; exit 1; }
done

# md5 on macOS, md5sum on Linux — this runs from either.
hash_of() {
	if command -v md5 >/dev/null 2>&1; then
		md5 -q "$1" | cut -c1-8
	else
		md5sum "$1" | cut -c1-8
	fi
}

CSS_HASH="$(hash_of "$CSS")"
PDF_HASH="$(hash_of "$PDF")"

python3 - "$CSS_HASH" "$PDF_HASH" "$HTML" "$HTML_DE" <<'PY'
import re, sys
css_h, pdf_h, paths = sys.argv[1], sys.argv[2], sys.argv[3:]

for path in paths:
  src = open(path).read()
  new = src

  new, n1 = re.subn(r'href="/style\.css(?:\?v=[^"]*)?"',
                    f'href="/style.css?v={css_h}"', new)
  if n1 == 0:
      sys.exit("error: no stylesheet link found in " + path)

  # The CV is replaced from time to time; without a stamp the edge would keep
  # serving the previous PDF under the same URL.
  new, n2 = re.subn(r'(?P<a>(?:href|data)="/cv\.pdf)(?:\?v=[^"]*)?"',
                    lambda m: f'{m.group("a")}?v={pdf_h}"', new)
  if n2 == 0:
      sys.exit("error: no CV reference found in " + path)

  if new != src:
      open(path, 'w').write(new)
      print(f"stamped {path}: css={css_h} cv={pdf_h} ({n1}+{n2} refs)")
  else:
      print(f"already current: {path}")
PY
