#!/usr/bin/env bash
# Generates LyricoMod.xcodeproj from project.yml with XcodeGen.
# Every Swift package in ios/Packages/<Name>/ (with a Package.swift) is added as a local package and
# its product <Name> is linked into the app (override products with Packages/<Name>/.xcodegen-products,
# one product per line). App code guards optional modules with `#if canImport(<Name>)`.
set -euo pipefail
IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$IOS_DIR"
python3 - <<'PY'
import os, re
ios = os.getcwd()
spec = open(os.path.join(ios, "project.yml"), encoding="utf-8").read()
pk_lines, dep_lines = [], []
pkg_root = os.path.join(ios, "Packages")
if os.path.isdir(pkg_root):
    for name in sorted(os.listdir(pkg_root)):
        d = os.path.join(pkg_root, name)
        if not os.path.isfile(os.path.join(d, "Package.swift")):
            continue
        products = [name]
        pf = os.path.join(d, ".xcodegen-products")
        if os.path.isfile(pf):
            products = [l.strip() for l in open(pf, encoding="utf-8") if l.strip() and not l.startswith("#")]
        pk_lines.append(f"  {name}:\n    path: Packages/{name}")
        for p in products:
            dep_lines.append(f"      - package: {name}\n        product: {p}")
        print(f"optional package: {name} -> {products}")
spec = spec.replace("  # @OPTIONAL_PACKAGES@", "\n".join(pk_lines) or "  # (no local packages)")
spec = spec.replace("      # @OPTIONAL_DEPENDENCIES@", "\n".join(dep_lines) or "      # (no local packages)")
open(os.path.join(ios, ".project.gen.yml"), "w", encoding="utf-8").write(spec)
PY
xcodegen generate --spec .project.gen.yml --project "$IOS_DIR"
