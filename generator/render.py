#!/usr/bin/env python3
"""
render.py — generates all per-service configuration from services.yml.

WHY THIS EXISTS
    Declaring a service normally means touching the Caddyfile, the tunnel
    config, an env file and the docs. Four files, four chances to forget one,
    and the drift is silent until something breaks at 2am. Here, services.yml
    is the only place a service is declared and this script derives the rest.
    See ADR-0014.

WHY THE OUTPUT IS COMMITTED, NOT GITIGNORED
    A generator you must run to know what is deployed is a black box. By
    committing the output:
      - you can read the actual Caddy config without running Python
      - `git diff` shows exactly what a registry change did
      - the server never needs Python installed
    `make check` re-renders and fails if the result differs from what is
    committed, so stale output cannot survive a commit (pre-commit enforces).

DESIGN NOTE — deliberately boring
    Plain Python + Jinja2, no framework, no plugins, no dynamic imports. This
    file should be fully understandable in one sitting three years from now.

USAGE
    python3 generator/render.py            # write files
    python3 generator/render.py --check    # exit 1 if output would change
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("error: pyyaml missing. Run `make setup`.")

try:
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
except ImportError:
    sys.exit("error: jinja2 missing. Run `make setup`.")

REPO = Path(__file__).resolve().parent.parent
REGISTRY = REPO / "services.yml"
TEMPLATES = REPO / "generator" / "templates"

# Networks a service may join. Kept in sync with ADR-0004.
VALID_NETWORKS = {"edge", "apps", "data"}
VALID_ACCESS = {"private", "public"}
VALID_ENVS = {"prod", "dev"}
NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")

# template -> output path, relative to repo root.
OUTPUTS = {
    "Caddyfile.j2": "compose/generated/caddy/Caddyfile",
    "cloudflared-config.yml.j2": "compose/generated/cloudflared/config.yml",
    "services.env.j2": "compose/generated/services.env",
    "SERVICES.md.j2": "docs/generated/SERVICES.md",
}


class RegistryError(Exception):
    """Raised when services.yml is invalid. Message is shown to the user."""


def load_services() -> list[dict]:
    """Read and validate services.yml.

    Validation is strict and fails loudly. A typo in a service name would
    otherwise surface as a 404 on a hostname that silently never routed —
    much harder to debug than an error here.
    """
    if not REGISTRY.exists():
        raise RegistryError(f"{REGISTRY} not found")

    raw = yaml.safe_load(REGISTRY.read_text()) or {}
    services = raw.get("services")
    if not isinstance(services, list):
        raise RegistryError("services.yml must contain a top-level 'services:' list")

    seen_names: set[str] = set()
    seen_ports: dict[int, str] = {}
    result: list[dict] = []

    for i, svc in enumerate(services):
        where = f"services[{i}]"
        if not isinstance(svc, dict):
            raise RegistryError(f"{where}: must be a mapping")

        name = svc.get("name")
        if not name or not isinstance(name, str):
            raise RegistryError(f"{where}: 'name' is required")
        if not NAME_RE.match(name):
            raise RegistryError(
                f"{where}: name {name!r} is not a valid DNS label "
                "(lowercase letters, digits, hyphens; must not start/end with '-')"
            )
        if name in seen_names:
            raise RegistryError(f"{where}: duplicate service name {name!r}")
        seen_names.add(name)

        port = svc.get("port")
        if not isinstance(port, int) or not (1 <= port <= 65535):
            raise RegistryError(f"{where} ({name}): 'port' must be an int 1-65535")

        description = svc.get("description")
        if not description or not isinstance(description, str):
            raise RegistryError(f"{where} ({name}): 'description' is required")

        networks = svc.get("networks")
        if not isinstance(networks, list) or not networks:
            raise RegistryError(f"{where} ({name}): 'networks' must be a non-empty list")
        bad = set(networks) - VALID_NETWORKS
        if bad:
            raise RegistryError(
                f"{where} ({name}): unknown network(s) {sorted(bad)}. "
                f"Valid: {sorted(VALID_NETWORKS)} (ADR-0004)"
            )

        access = svc.get("access")
        if access not in VALID_ACCESS:
            raise RegistryError(
                f"{where} ({name}): 'access' must be one of {sorted(VALID_ACCESS)}"
            )

        envs = svc.get("envs", ["prod", "dev"])
        bad_envs = set(envs) - VALID_ENVS
        if bad_envs:
            raise RegistryError(f"{where} ({name}): unknown env(s) {sorted(bad_envs)}")

        enabled = svc.get("enabled", True)
        if not isinstance(enabled, bool):
            raise RegistryError(f"{where} ({name}): 'enabled' must be true or false")

        # Port collisions only matter among services actually deployed.
        if enabled:
            if port in seen_ports:
                raise RegistryError(
                    f"{where} ({name}): port {port} already used by "
                    f"{seen_ports[port]!r}. Two enabled services cannot share a port."
                )
            seen_ports[port] = name

        result.append(
            {
                "name": name,
                "port": port,
                "description": description,
                "networks": networks,
                "access": access,
                "envs": envs,
                "healthcheck": svc.get("healthcheck", "/"),
                "enabled": enabled,
                # Uppercased name for env var keys: n8n -> N8N
                "env_key": name.upper().replace("-", "_"),
            }
        )

    return result


def build_context(services: list[dict]) -> dict:
    """Assemble the template context.

    Note what is absent: DOMAIN and ENV. Hostnames are NOT baked in at render
    time — templates emit `{$DOMAIN}` style references that Caddy and compose
    resolve at runtime from .env. That is what makes one committed artifact
    correct for both prod and dev without re-rendering (ADR-0010).
    """
    return {
        "services": services,
        "enabled_services": [s for s in services if s["enabled"]],
        "generator": "generator/render.py",
        "registry": "services.yml",
    }


def render_all(check_only: bool = False) -> int:
    services = load_services()
    jinja_env = Environment(
        loader=FileSystemLoader(TEMPLATES),
        undefined=StrictUndefined,  # a typo'd variable is an error, not ""
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
    )
    ctx = build_context(services)

    stale: list[str] = []
    written: list[str] = []

    for template_name, out_rel in OUTPUTS.items():
        template = jinja_env.get_template(template_name)
        content = template.render(**ctx)
        out_path = REPO / out_rel

        if check_only:
            current = out_path.read_text() if out_path.exists() else None
            if current != content:
                stale.append(out_rel)
        else:
            out_path.parent.mkdir(parents=True, exist_ok=True)
            if not out_path.exists() or out_path.read_text() != content:
                out_path.write_text(content)
                written.append(out_rel)

    if check_only:
        if stale:
            print("STALE — generated files do not match services.yml:", file=sys.stderr)
            for f in stale:
                print(f"  {f}", file=sys.stderr)
            print("\nRun `make generate` and commit the result.", file=sys.stderr)
            return 1
        print(f"OK — {len(OUTPUTS)} generated files match services.yml")
        return 0

    for f in written:
        print(f"  wrote {f}")
    if not written:
        print("  (no changes)")
    print(f"OK — {len(ctx['enabled_services'])}/{len(services)} services enabled")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Render config from services.yml")
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if generated files are stale; write nothing",
    )
    args = parser.parse_args()

    try:
        return render_all(check_only=args.check)
    except RegistryError as e:
        print(f"services.yml: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
