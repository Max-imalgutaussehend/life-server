
## Changing the CSS

Run `./scripts/portfolio-stamp.sh` before deploying. It appends style.css's
own content hash to the `<link>` in index.html.

Without it, a CSS change can sit invisible behind Cloudflare's edge cache
while the HTML is already current — the page then renders new markup with old
rules, which looks exactly like a deploy that did nothing. Measured while
building this site: `cf-cache-status: HIT, age: 614` on style.css against a
`DYNAMIC` HTML response.

`Cache-Control` is deliberately short here (300s in the Caddyfile, see the
comment there), but a short cache only shrinks that window. The hash closes it.
