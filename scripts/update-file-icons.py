#!/usr/bin/env python3
"""Vendor the file icons of Material Icon Theme (MIT) into the native app.

Usage: python3 -I scripts/update-file-icons.py <extracted npm package dir>
       (npm pack material-icon-theme && tar -xzf material-icon-theme-*.tgz)

Copies only the SVGs referenced by file names, file extensions and language ids,
plus a compact mapping (FileIcons/map.json) and the upstream license.
"""
import json
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "native", "Sources", "ButakeGit", "FileIcons")
# Extensions VS Code resolves through language ids instead of fileExtensions.
LANGUAGE_EXTENSIONS = {
    "php": "php", "py": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript",
    "ts": "typescript", "jsx": "javascriptreact", "md": "markdown", "css": "css", "scss": "scss",
    "less": "less", "html": "html", "htm": "html", "json": "json", "yml": "yaml", "yaml": "yaml",
    "xml": "xml", "sh": "shellscript", "zsh": "shellscript", "bash": "shellscript", "sql": "sql",
    "rb": "ruby", "go": "go", "java": "java", "c": "c", "h": "c", "cpp": "cpp", "cs": "csharp",
    "swift": "swift", "rs": "rust", "lua": "lua", "dart": "dart", "r": "r", "ps1": "powershell",
    "bat": "bat", "txt": "plaintext", "ini": "ini", "dockerfile": "dockerfile", "vue": "vue",
}
SAFE_NAME = re.compile(r"^[a-z0-9_.-]+$")


def main(package: str) -> None:
    mapping = json.load(open(os.path.join(package, "dist", "material-icons.json")))
    definitions = mapping["iconDefinitions"]
    language = mapping["languageIds"]
    extensions = dict(mapping["fileExtensions"])
    for ext, lang in LANGUAGE_EXTENSIONS.items():
        if ext not in extensions and lang in language:
            extensions[ext] = language[lang]
    light = mapping.get("light", {})
    result = {
        "file": mapping["file"],
        "names": {k.lower(): v for k, v in mapping["fileNames"].items()},
        "extensions": {k.lower(): v for k, v in extensions.items()},
        "lightNames": {k.lower(): v for k, v in light.get("fileNames", {}).items()},
        "lightExtensions": {k.lower(): v for k, v in light.get("fileExtensions", {}).items()},
    }
    used = {result["file"]}
    for key in ("names", "extensions", "lightNames", "lightExtensions"):
        used.update(result[key].values())

    if os.path.isdir(TARGET):
        shutil.rmtree(TARGET)
    os.makedirs(TARGET)
    copied = 0
    for icon in sorted(used):
        definition = definitions.get(icon)
        if not definition or not SAFE_NAME.match(icon):
            continue
        source = os.path.join(package, "icons", os.path.basename(definition["iconPath"]))
        svg = open(source, encoding="utf-8").read()
        if re.search(r"<script|on[a-z]+=|href=\"(?!#)", svg, re.IGNORECASE):
            sys.exit(f"Unsafe SVG content in {source}")
        with open(os.path.join(TARGET, icon + ".svg"), "w", encoding="utf-8") as out:
            out.write(svg)
        copied += 1
    # Drop mappings whose icon could not be copied.
    available = {name[:-4] for name in os.listdir(TARGET) if name.endswith(".svg")}
    for key in ("names", "extensions", "lightNames", "lightExtensions"):
        result[key] = {k: v for k, v in result[key].items() if v in available}
    version = json.load(open(os.path.join(package, "package.json")))["version"]
    result["version"] = version
    with open(os.path.join(TARGET, "map.json"), "w", encoding="utf-8") as out:
        json.dump(result, out, separators=(",", ":"), sort_keys=True)
    shutil.copy(os.path.join(package, "LICENSE"), os.path.join(TARGET, "LICENSE-material-icon-theme.txt"))
    print(f"Material Icon Theme {version}: {copied} icons, {len(result['names'])} names, {len(result['extensions'])} extensions")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
