#!/usr/bin/env python3
"""P1-012: turn trivy JSON reports into a pass/fail gate.

The gate fails when a report contains a finding whose severity is in
``--fail-on`` and which the allowlist does not cover. An allowlist entry only
covers one CVE for one image, and it expires: a temporary suppression cannot
silently become permanent.

Allowlist format (JSON, no third-party parser needed):

    [
      {
        "id": "CVE-2024-1234",
        "image": "feldera-manager",   # substring match on the image name
        "reason": "not reachable in our deployment",
        "expires": "2026-12-31"       # inclusive last day
      }
    ]
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Finding:
    image: str
    vulnerability_id: str
    package: str
    installed: str
    fixed: str
    severity: str


def load_report(path: str) -> tuple[str, list[Finding]]:
    with open(path, encoding="utf-8") as handle:
        report = json.load(handle)
    image = report.get("ArtifactName") or os.path.basename(path)
    findings: list[Finding] = []
    for result in report.get("Results") or []:
        for entry in result.get("Vulnerabilities") or []:
            findings.append(
                Finding(
                    image=image,
                    vulnerability_id=entry.get("VulnerabilityID", "?"),
                    package=entry.get("PkgName", "?"),
                    installed=entry.get("InstalledVersion", "?"),
                    fixed=entry.get("FixedVersion") or "no fix",
                    severity=(entry.get("Severity") or "UNKNOWN").upper(),
                )
            )
    return image, findings


def load_allowlist(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        entries = json.load(handle)
    if not isinstance(entries, list):
        raise SystemExit(f"{path}: expected a JSON list of allowlist entries")
    return entries


def allows(entries: list[dict], finding: Finding, today: dt.date) -> dict | None:
    for entry in entries:
        if entry.get("id") != finding.vulnerability_id:
            continue
        if entry.get("image") and entry["image"] not in finding.image:
            continue
        expires = entry.get("expires")
        if expires:
            try:
                last_day = dt.date.fromisoformat(expires)
            except ValueError:
                raise SystemExit(
                    f"allowlist entry {finding.vulnerability_id}: bad expires {expires!r}"
                ) from None
            if today > last_day:
                # An expired suppression never applies; the finding is shown
                # again so that the owner has to renew it deliberately.
                continue
        return entry
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", help="trivy JSON report files")
    parser.add_argument("--allowlist", default="deploy/security/vulnerability-allowlist.json")
    parser.add_argument("--fail-on", default="CRITICAL,HIGH")
    parser.add_argument(
        "--summary",
        action="store_true",
        help="only print per-image counts; never fail",
    )
    arguments = parser.parse_args()

    fail_on = {item.strip().upper() for item in arguments.fail_on.split(",") if item.strip()}
    entries = load_allowlist(arguments.allowlist)
    today = dt.date.today()

    blocked: list[Finding] = []
    allowed: list[tuple[Finding, dict]] = []
    per_image: dict[str, dict[str, int]] = {}

    for path in arguments.reports:
        image, findings = load_report(path)
        counts = per_image.setdefault(image, {})
        for finding in findings:
            counts[finding.severity] = counts.get(finding.severity, 0) + 1
            if arguments.summary or finding.severity not in fail_on:
                continue
            entry = allows(entries, finding, today)
            if entry is None:
                blocked.append(finding)
            else:
                allowed.append((finding, entry))

    print(f"{'IMAGE':<52} {'CRIT':>5} {'HIGH':>5} {'MED':>5} {'LOW':>5}")
    for image, counts in sorted(per_image.items()):
        print(
            f"{image[:52]:<52} {counts.get('CRITICAL', 0):>5} "
            f"{counts.get('HIGH', 0):>5} {counts.get('MEDIUM', 0):>5} "
            f"{counts.get('LOW', 0):>5}"
        )

    if arguments.summary:
        return 0

    for finding, entry in allowed:
        print(
            f"ALLOWED  {finding.vulnerability_id:<18} {finding.image:<40} "
            f"until {entry.get('expires', 'never')}: {entry.get('reason', 'no reason')}"
        )
    for finding in blocked:
        print(
            f"BLOCKED  {finding.vulnerability_id:<18} {finding.image:<40} "
            f"{finding.package} {finding.installed} -> {finding.fixed} ({finding.severity})"
        )

    if blocked:
        print(
            f"\nGATE FAILED: {len(blocked)} finding(s) at {','.join(sorted(fail_on))} "
            f"without an allowlist entry (see {arguments.allowlist})",
            file=sys.stderr,
        )
        return 1

    print(
        f"\nGATE PASSED: no {','.join(sorted(fail_on))} findings outside the allowlist "
        f"({len(allowed)} allowed by {arguments.allowlist})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
