"""Print one version's section of CHANGELOG.md.

    python3 build/ci/changelog-section.py CHANGELOG.md v1.0.0

Used by the release workflow to put what CHANGED into the release notes.
build-info.json can only describe what a release IS - its DriverVer, its signer,
its prerequisites - so without this the notes would never say what was different
about it.

Exits 1 if the tag has no section, which is deliberate: publishing a release
whose changelog entry was forgotten is the mistake worth catching, and it costs
a re-tag to fix afterwards.
"""

from __future__ import annotations

import re
import sys


def section(markdown: str, version: str) -> str:
    """Return the body of the `## [version]` section, without its heading.

    Accepts the tag with or without its leading `v`, since the changelog holds
    bare versions and the workflow has a tag name.
    """
    wanted = version.lstrip('v')

    # Headings look like `## [1.0.0] - 2026-09-05`, and the link-reference
    # definitions at the foot of the file (`[1.0.0]: https://...`) must not be
    # mistaken for one - hence anchoring to the `##`.
    heading = re.compile(r'^##\s+\[?([^\]\s]+)\]?', re.MULTILINE)

    matches = list(heading.finditer(markdown))
    for index, match in enumerate(matches):
        if match.group(1).lstrip('v') != wanted:
            continue
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(markdown)
        body = markdown[start:end]

        # Drop the rest of the heading line (the date) and the link-reference
        # definitions, which are markdown plumbing rather than content.
        body = body.split('\n', 1)[1] if '\n' in body else ''
        body = re.sub(r'^\[[^\]]+\]:\s*\S+\s*$', '', body, flags=re.MULTILINE)
        return body.strip()

    return ''


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    # The changelog is UTF-8 and contains em dashes; do not let the platform's
    # default console encoding decide whether they survive. On Windows stdout
    # defaults to a legacy code page and would replace them with '?'.
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', newline='\n')

    path, version = argv[1], argv[2]
    with open(path, encoding='utf-8') as handle:
        body = section(handle.read(), version)

    if not body:
        print(f'{path} has no section for {version}', file=sys.stderr)
        return 1

    print(body)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
