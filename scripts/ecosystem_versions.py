#!/usr/bin/env python3
"""Validate the ModEdit ecosystem tag graph.

`Release/EcosystemVersions.json` records the published tag for every component
in the ecosystem release graph, plus the support packages ModEdit uses
directly. This tool checks that:

  * the snapshot is well formed and has no duplicate names or identities;
  * ModEdit has no local filesystem package dependencies;
  * every direct dependency resolves to the tag recorded in the snapshot;
  * ModEdit's Version.json matches its own tag in the snapshot; and
  * optionally, every sibling checkout is exactly at the recorded tag.

The snapshot is deliberately separate from Grammar-Workbench's compatibility
lock. A shared tag list answers "what was published?"; a compatibility lock
answers "what has been tested together?".
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Release/EcosystemVersions.json"
PACKAGE = ROOT / "Package.swift"
RESOLVED = ROOT / "Package.resolved"
VERSION_JSON = ROOT / "Version.json"

SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
LAYERS = {0, 1, 2, 3, 4}
ROLES = {"foundation", "engine", "support", "tooling", "language-kit", "product"}


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_manifest() -> dict:
    if not MANIFEST.exists():
        fail(f"{MANIFEST} is missing")
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{MANIFEST} is not valid JSON: {exc}")
    if not isinstance(data, dict):
        fail(f"{MANIFEST} must contain a JSON object")
    return data


def validate_schema(data: dict) -> list[str]:
    errors: list[str] = []
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    components = data.get("components")
    if not isinstance(components, list) or not components:
        errors.append("components must be a non-empty array")
        return errors

    names: set[str] = set()
    identities: set[str] = set()
    for index, component in enumerate(components):
        label = f"components[{index}]"
        if not isinstance(component, dict):
            errors.append(f"{label} must be an object")
            continue
        name = component.get("name")
        identity = component.get("swiftPMIdentity")
        tag = component.get("tag")
        layer = component.get("layer")
        role = component.get("role")
        direct = component.get("directDependency")

        if not isinstance(name, str) or not name:
            errors.append(f"{label}.name must be a non-empty string")
        elif name in names:
            errors.append(f"duplicate component name {name!r}")
        else:
            names.add(name)

        if not isinstance(identity, str) or not identity:
            errors.append(f"{label}.swiftPMIdentity must be a non-empty string")
        elif identity in identities:
            errors.append(f"duplicate SwiftPM identity {identity!r}")
        else:
            identities.add(identity)

        if not isinstance(tag, str) or not SEMVER.fullmatch(tag):
            errors.append(f"{label}.tag must look like MAJOR.MINOR.PATCH")
        if layer not in LAYERS:
            errors.append(f"{label}.layer must be one of {sorted(LAYERS)}")
        if role not in ROLES:
            errors.append(f"{label}.role must be one of {sorted(ROLES)}")
        if not isinstance(direct, bool):
            errors.append(f"{label}.directDependency must be true or false")

    external = data.get("externalDependencies", [])
    if not isinstance(external, list):
        errors.append("externalDependencies must be an array")
    else:
        for index, component in enumerate(external):
            label = f"externalDependencies[{index}]"
            if not isinstance(component, dict):
                errors.append(f"{label} must be an object")
                continue
            name = component.get("name")
            identity = component.get("swiftPMIdentity")
            url = component.get("url")
            tag = component.get("tag")
            direct = component.get("directDependency")

            if not isinstance(name, str) or not name:
                errors.append(f"{label}.name must be a non-empty string")
            elif name in names:
                errors.append(f"duplicate component name {name!r}")
            else:
                names.add(name)

            if not isinstance(identity, str) or not identity:
                errors.append(
                    f"{label}.swiftPMIdentity must be a non-empty string"
                )
            elif identity in identities:
                errors.append(f"duplicate SwiftPM identity {identity!r}")
            else:
                identities.add(identity)

            if not isinstance(url, str) or not url.startswith("https://"):
                errors.append(f"{label}.url must be an https:// URL")
            if not isinstance(tag, str) or not SEMVER.fullmatch(tag):
                errors.append(f"{label}.tag must look like MAJOR.MINOR.PATCH")
            if not isinstance(direct, bool):
                errors.append(f"{label}.directDependency must be true or false")
            reason = component.get("reason")
            if not isinstance(reason, str) or not reason:
                errors.append(f"{label}.reason must be a non-empty string")

    drift = data.get("knownModEditDrift", {})
    if not isinstance(drift, dict):
        errors.append("knownModEditDrift must be an object")
    else:
        direct_identities = {
            component.get("swiftPMIdentity")
            for component in components
            if isinstance(component, dict) and component.get("directDependency")
        }
        for identity, entry in drift.items():
            if identity not in direct_identities:
                errors.append(
                    f"knownModEditDrift.{identity} is not a direct dependency"
                )
            if not isinstance(entry, dict):
                errors.append(f"knownModEditDrift.{identity} must be an object")
                continue
            resolved = entry.get("resolved")
            if not isinstance(resolved, str) or not SEMVER.fullmatch(resolved):
                errors.append(
                    f"knownModEditDrift.{identity}.resolved must look like "
                    "MAJOR.MINOR.PATCH"
                )
            if not isinstance(entry.get("reason"), str) or not entry["reason"]:
                errors.append(
                    f"knownModEditDrift.{identity}.reason must be a non-empty string"
                )

    return errors


def resolved_pins() -> dict[str, dict]:
    if not RESOLVED.exists():
        return {}
    try:
        data = json.loads(RESOLVED.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{RESOLVED} is not valid JSON: {exc}")
    pins: dict[str, dict] = {}
    for pin in data.get("pins", []):
        identity = pin.get("identity")
        if isinstance(identity, str):
            pins[identity] = pin
    return pins


def resolved_version(pins: dict[str, dict], identity: str) -> str:
    return pins.get(identity, {}).get("state", {}).get("version", "-")


def check_local_paths() -> list[str]:
    errors: list[str] = []
    package_text = PACKAGE.read_text(encoding="utf-8")
    if ".package(path:" in package_text:
        errors.append("Package.swift contains a .package(path:) dependency")
    if "file://" in package_text:
        errors.append("Package.swift contains a file:// dependency")

    if RESOLVED.exists():
        data = json.loads(RESOLVED.read_text(encoding="utf-8"))
        for pin in data.get("pins", []):
            location = pin.get("location", "")
            identity = pin.get("identity", "<unknown>")
            if not isinstance(location, str) or not location.startswith("https://"):
                errors.append(
                    f"{identity} resolves from {location!r}, not an https:// URL"
                )
    return errors


def check_external_declarations(data: dict) -> list[str]:
    """Require direct external dependencies to use exact pins in Package.swift."""
    errors: list[str] = []
    package_text = PACKAGE.read_text(encoding="utf-8")
    for component in data.get("externalDependencies", []):
        if not component.get("directDependency"):
            continue
        partial = re.compile(
            r"\.package\(\s*url:\s*\""
            + re.escape(component["url"])
            + r"\"\s*,\s*exact:\s*\""
            + re.escape(component["tag"])
            + r"\"\s*\)"
        )
        if not partial.search(package_text):
            errors.append(
                f"{component['name']}: Package.swift must declare "
                f'.package(url: "{component["url"]}", exact: '
                f'"{component["tag"]}")'
            )
    return errors


def check_resolved_dependencies(data: dict) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    pins = resolved_pins()
    known_drift = data.get("knownModEditDrift", {})
    for component in data["components"]:
        name = component["name"]
        identity = component["swiftPMIdentity"]
        expected = component["tag"]
        pin = pins.get(identity)
        if pin is None:
            if component.get("directDependency"):
                errors.append(f"{name}: no pin for SwiftPM identity {identity!r}")
            continue
        version = pin.get("state", {}).get("version")
        if not isinstance(version, str):
            errors.append(
                f"{name}: resolved from a branch or revision, not a tagged release"
            )
            continue
        if version == expected:
            continue

        drift = known_drift.get(identity)
        if isinstance(drift, dict) and drift.get("resolved") == version:
            warnings.append(
                f"{name}: known drift — ModEdit resolves {version}, ecosystem tag "
                f"is {expected}. {drift['reason']}"
            )
        else:
            errors.append(
                f"{name}: ModEdit resolves {version}, ecosystem tag is {expected}; "
                "update the pin or record a known drift entry with a reason"
            )

    for component in data.get("externalDependencies", []):
        name = component["name"]
        identity = component["swiftPMIdentity"]
        expected = component["tag"]
        pin = pins.get(identity)
        if pin is None:
            if component.get("directDependency"):
                errors.append(
                    f"{name}: no pin for external SwiftPM identity {identity!r}"
                )
            continue
        version = pin.get("state", {}).get("version")
        if not isinstance(version, str):
            errors.append(
                f"{name}: resolved from a branch or revision, not the exact "
                f"recorded tag {expected}"
            )
            continue
        if version != expected:
            errors.append(
                f"{name}: ModEdit resolves external dependency {version}, "
                f"recorded exact pin is {expected}; update the pin and this "
                "snapshot together"
            )
        location = pin.get("location")
        if location != component["url"]:
            errors.append(
                f"{name}: resolves from {location!r}, recorded URL is "
                f"{component['url']!r}"
            )
    return errors, warnings


def check_modedit_version(components: list[dict]) -> list[str]:
    if not VERSION_JSON.exists():
        return ["Version.json is missing"]
    version = json.loads(VERSION_JSON.read_text(encoding="utf-8"))
    marketing = version.get("marketingVersion")
    modedit = next(
        (component for component in components if component["name"] == "ModEdit"),
        None,
    )
    if modedit is None:
        return ["the snapshot has no ModEdit component"]
    if marketing != modedit["tag"]:
        return [
            f"Version.json says {marketing!r}, but the snapshot tags ModEdit "
            f"{modedit['tag']!r}; bump the version or update the snapshot"
        ]
    return []


def component_tags(repository: Path) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(repository), "tag", "--points-at", "HEAD"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    return [
        tag
        for tag in result.stdout.split()
        if SEMVER.fullmatch(tag)
    ]


def audit_siblings(data: dict, root: Path) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    components = data["components"]

    for component in components:
        name = component["name"]
        expected = component["tag"]
        repository = root / name
        if not (repository / ".git").exists():
            errors.append(f"{name}: no git repository at {repository}")
            continue

        tags = component_tags(repository)
        if expected not in tags:
            actual = ", ".join(tags) if tags else "untagged HEAD"
            errors.append(f"{name}: expected tag {expected}, found {actual}")
            continue

        status = subprocess.run(
            ["git", "-C", str(repository), "status", "--porcelain"],
            capture_output=True,
            text=True,
        )
        if status.stdout.strip():
            warnings.append(f"{name}: working tree has local changes")

    return errors, warnings


def update_siblings(data: dict, root: Path) -> None:
    components = data["components"]
    new_tags: dict[str, str] = {}
    for component in components:
        name = component["name"]
        repository = root / name
        if not (repository / ".git").exists():
            fail(f"{name}: no git repository at {repository}")
        tags = component_tags(repository)
        if len(tags) != 1:
            fail(
                f"{name}: expected exactly one semver tag at HEAD, found "
                f"{tags or ['none']}"
            )
        new_tags[name] = tags[0]

    text = MANIFEST.read_text(encoding="utf-8")
    for name, tag in new_tags.items():
        pattern = re.compile(
            r'("name"\s*:\s*"' + re.escape(name) + r'"[^{}]*?"tag"\s*:\s*")[^"]*(")',
            re.DOTALL,
        )
        text, count = pattern.subn(
            lambda match: f"{match.group(1)}{tag}{match.group(2)}", text
        )
        if count != 1:
            fail(f"{name}: could not find exactly one tag field in the snapshot")

    snapshot_date = subprocess.check_output(
        ["date", "+%Y-%m-%d"], text=True
    ).strip()
    date_pattern = re.compile(r'("snapshotDate"\s*:\s*")[^"]*(")')
    text, date_count = date_pattern.subn(
        lambda match: f"{match.group(1)}{snapshot_date}{match.group(2)}",
        text,
        count=1,
    )
    if date_count != 1:
        fail("could not update snapshotDate in the snapshot")

    MANIFEST.write_text(text, encoding="utf-8")
    print(f"Updated {MANIFEST.relative_to(ROOT)} from {root}")


def print_table(data: dict) -> None:
    pins = resolved_pins()
    print(f"{'Component':28} {'Tag':9} {'Layer':5} {'Direct':6} {'Resolved':9}")
    print("-" * 66)
    for component in data["components"]:
        resolved = resolved_version(pins, component["swiftPMIdentity"])
        direct = "yes" if component["directDependency"] else "no"
        print(
            f"{component['name']:28} {component['tag']:9} "
            f"{component['layer']:<5} {direct:6} {resolved:9}"
        )

    external = data.get("externalDependencies", [])
    if external:
        print()
        print("External dependencies:")
        print(f"{'Package':28} {'Tag':9} {'Direct':7} {'Resolved':9}")
        print("-" * 57)
        for component in external:
            resolved = resolved_version(pins, component["swiftPMIdentity"])
            direct = "yes" if component["directDependency"] else "no"
            print(
                f"{component['name']:28} {component['tag']:9} "
                f"{direct:7} {resolved:9}"
            )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=os.environ.get("ECOSYSTEM_ROOT"),
        help="directory containing sibling ecosystem checkouts",
    )
    parser.add_argument(
        "--update",
        action="store_true",
        help="rewrite the snapshot from the sibling checkouts (requires --root)",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="only print problems and a one-line summary",
    )
    args = parser.parse_args(argv)

    data = load_manifest()
    errors = validate_schema(data)

    if args.update:
        if not args.root:
            fail("--update requires --root or ECOSYSTEM_ROOT")
        update_siblings(data, Path(args.root).expanduser().resolve())
        data = load_manifest()

    components = data.get("components", [])
    warnings: list[str] = []
    if not errors:
        errors.extend(check_local_paths())
        errors.extend(check_external_declarations(data))
        dependency_errors, dependency_warnings = check_resolved_dependencies(data)
        errors.extend(dependency_errors)
        warnings.extend(dependency_warnings)
        errors.extend(check_modedit_version(components))
    if args.root and not args.update:
        audit_errors, audit_warnings = audit_siblings(
            data, Path(args.root).expanduser().resolve()
        )
        errors.extend(audit_errors)
        warnings.extend(audit_warnings)

    if not args.quiet and not errors:
        print_table(data)

    if warnings:
        sys.stdout.flush()
        print("\nWarnings:", file=sys.stderr)
        for warning in warnings:
            print(f"  - {warning}", file=sys.stderr)

    if errors:
        print(f"\nEcosystem tag graph has {len(errors)} problem(s):", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    direct_count = sum(1 for component in components if component["directDependency"])
    pins = resolved_pins()
    resolved_count = sum(
        1 for component in components if component["swiftPMIdentity"] in pins
    )
    drift_count = len(data.get("knownModEditDrift", {}))
    matched_count = resolved_count - drift_count
    drift_note = f"; {drift_count} known drift" if drift_count else ""
    external = data.get("externalDependencies", [])
    external_matched = sum(
        1
        for component in external
        if resolved_version(pins, component["swiftPMIdentity"])
        == component["tag"]
    )
    external_note = (
        f" {external_matched}/{len(external)} external dependencies match "
        "their exact pins."
        if external
        else ""
    )
    print(
        f"Ecosystem tag graph OK: {len(components)} components; "
        f"{matched_count}/{resolved_count} resolved packages match published tags"
        f"{drift_note}; {direct_count} direct dependencies.{external_note}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
