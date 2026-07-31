#!/usr/bin/env python3
"""Turn a CEO agent's JSON plan into one INSERT statement. (M9)

Reads the plan on stdin, writes SQL to stdout. The parent ticket id comes from
the PARENT environment variable.

WHY THIS IS A FILE AND NOT INLINE IN THE SHELL SCRIPT
    It was inline, and it generated SQL containing 'worker' — which closed the
    single-quoted heredoc wrapping the Python and left shellcheck parsing
    Python as shell. Two languages sharing one quoting context is a trap; a
    file has its own.

WHY BASE64 AND NOT QUOTE-DOUBLING
    The strings here are written by a language model and routinely contain
    backslashes: code, file paths, escape sequences. psql reads a backslash at
    the start of a line as a meta-command, so a body containing a backslash
    sequence made psql answer `invalid command` and abandon the whole
    statement — silently, from the runner's point of view.

    Doubling quotes does not help, because the problem is not quoting: it is
    that the text is parsed at all. base64 is closed over every byte, so
    nothing in the value can be read as SQL or as a psql command. Postgres
    decodes it back to text on arrival.
"""

import base64
import json
import os
import sys

DOMAINS = ("uni", "work", "jobsearch", "personal", "projects")
PRIORITIES = ("low", "normal", "high", "urgent")

# Titles are shown in list output; a runaway title from a confused model should
# not make the queue unreadable.
MAX_TITLE = 500


def b64(value):
    """A SQL expression that evaluates to `value`, immune to any byte in it."""
    encoded = base64.b64encode(str(value).encode("utf-8")).decode("ascii")
    return "convert_from(decode('{}','base64'),'UTF8')".format(encoded)


def lit(value):
    """A plain SQL literal. Only for values already checked against a whitelist."""
    return "'{}'".format(str(value).replace("'", "''"))


def main():
    parent = os.environ.get("PARENT", "")
    if not parent.isdigit():
        sys.exit("PARENT must be a numeric ticket id")

    # A model can emit almost-JSON. Report that as one clear line rather than a
    # traceback: this runs unattended, and the runner logs only the first ~150
    # characters of stderr, so a stack trace would bury the actual reason.
    try:
        rows = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        sys.exit("CEO plan is not valid JSON: {}".format(exc))

    if not isinstance(rows, list) or not rows:
        sys.exit("plan must be a non-empty JSON array")

    values = []
    for row in rows:
        if not isinstance(row, dict):
            continue

        # Fall back rather than reject: a plan with one odd priority is still a
        # useful plan, and discarding it would lose the CEO's whole run.
        priority = row.get("priority", "normal")
        if priority not in PRIORITIES:
            priority = "normal"

        domain = row.get("domain") or "personal"
        if domain not in DOMAINS:
            domain = "personal"

        title = str(row.get("title", "untitled"))[:MAX_TITLE]

        values.append(
            "({}, {}, {}, {}::ticket_priority, {}, {})".format(
                b64(title), b64(row.get("body", "")),
                lit(domain), lit(priority), parent, lit("worker"),
            )
        )

    if not values:
        sys.exit("plan contained no usable tickets")

    print(
        "INSERT INTO tickets (title, body, domain, priority, parent_id, role) "
        "VALUES " + ", ".join(values) + ";"
    )


if __name__ == "__main__":
    main()
