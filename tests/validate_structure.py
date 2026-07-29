#!/usr/bin/env python3
"""Structure and consistency checks for the oh-my-axon tree.

    python3 tests/validate_structure.py

Validates the things the installers copy but never inspect: agent and skill
frontmatter, hook descriptors, persona TOML, and cross-file agreement between
the two installers and the README. Stdlib only -- no PyYAML, no pip install.

Exits non-zero if any check fails.
"""

import json
import re
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    tomllib = None

REPO = Path(__file__).resolve().parent.parent
HOME = REPO / "home"

CAPABILITY_MODES = {"read-only", "read-write", "execute", "all"}

# Agents may pin a model, but only by a generic name the user maps in their
# own config.toml. A concrete model key here would hard-code one person's
# setup into a public repo.
ALLOWED_MODEL_NAMES = {"vision"}

checks = 0
failures = 0


def ok(name):
    global checks
    checks += 1
    print(f"  ok   {name}")


def bad(name, detail=""):
    global checks, failures
    checks += 1
    failures += 1
    print(f"  FAIL {name}")
    if detail:
        print(f"       {detail}")


def check(name, condition, detail=""):
    if condition:
        ok(name)
    else:
        bad(name, detail)


def parse_frontmatter(path):
    """Return (keys, error). keys maps top-level frontmatter key -> inline value.

    Deliberately not a YAML parser. These files use folded scalars
    (`description: >`) and one nested block (`metadata:`), so anything
    indented is a continuation of the key above it and is skipped; the value
    recorded is whatever sat on the key's own line.
    """
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return None, "no opening --- frontmatter delimiter"
    lines = text.splitlines()
    end = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            end = i
            break
    if end is None:
        return None, "no closing --- frontmatter delimiter"

    keys = {}
    last_key = None
    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[0] in " \t":  # continuation of the previous key
            if last_key is not None and not keys[last_key]:
                keys[last_key] = line.strip()
            continue
        m = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", line)
        if m:
            last_key = m.group(1)
            value = m.group(2).strip()
            keys[last_key] = "" if value in (">", "|") else value
    return keys, None


def check_agents():
    print("\nagents")
    agent_files = sorted((HOME / "agents").glob("*.md"))
    check("at least one agent is shipped", len(agent_files) > 0)
    names = []
    for path in agent_files:
        rel = path.relative_to(REPO)
        keys, err = parse_frontmatter(path)
        if err:
            bad(f"{rel}: has frontmatter", err)
            continue
        for required in ("name", "description", "capabilityMode"):
            check(f"{rel}: has {required}", required in keys,
                  f"frontmatter keys found: {sorted(keys)}")
        name = keys.get("name", "")
        names.append(name)
        check(f"{rel}: name matches filename", name == path.stem,
              f"name={name!r} stem={path.stem!r}")
        check(f"{rel}: description is non-empty", bool(keys.get("description")))
        mode = keys.get("capabilityMode", "")
        check(f"{rel}: capabilityMode is valid", mode in CAPABILITY_MODES,
              f"{mode!r} not in {sorted(CAPABILITY_MODES)}")
        if "model" in keys:
            check(f"{rel}: model is a generic name",
                  keys["model"] in ALLOWED_MODEL_NAMES,
                  f"{keys['model']!r} is not in {sorted(ALLOWED_MODEL_NAMES)}; "
                  "a public repo must not pin a user-specific model key")
    return [n for n in names if n]


def check_skills():
    print("\nskills")
    skill_dirs = sorted(d for d in (HOME / "skills").iterdir() if d.is_dir())
    check("at least one skill is shipped", len(skill_dirs) > 0)
    names = []
    for d in skill_dirs:
        path = d / "SKILL.md"
        if not path.is_file():
            bad(f"skills/{d.name}: has SKILL.md", f"missing {path}")
            continue
        keys, err = parse_frontmatter(path)
        if err:
            bad(f"skills/{d.name}: has frontmatter", err)
            continue
        check(f"skills/{d.name}: has name", "name" in keys)
        check(f"skills/{d.name}: has description", bool(keys.get("description")))
        name = keys.get("name", "")
        names.append(name)
        check(f"skills/{d.name}: name matches directory", name == d.name,
              f"name={name!r} dir={d.name!r}")
    return [n for n in names if n]


def check_hooks():
    print("\nhook descriptors")
    # The events Axon dispatches, under their canonical names. SubagentEnd is
    # deliberately absent: Axon accepts it as an alias, but only since 0.3.5 --
    # before that a hook registered under it landed in a bucket nothing fired
    # and never ran, silently. SubagentStop is the name to write.
    valid_events = {
        "SessionStart",
        "SessionEnd",
        "PreToolUse",
        "PostToolUse",
        "PreCompact",
        "SubagentStop",
        "Stop",
        "UserPromptSubmit",
        "Notification",
    }
    for path in sorted((HOME / "hooks").glob("*.json")):
        rel = path.relative_to(REPO)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            bad(f"{rel}: is valid JSON", str(exc))
            continue
        ok(f"{rel}: is valid JSON")
        events = data.get("hooks", {})
        check(f"{rel}: declares at least one event", bool(events))
        for event, entries in events.items():
            check(f"{rel}: {event} is a known event", event in valid_events,
                  f"{event!r} not in {sorted(valid_events)}")
            for entry in entries:
                for hook in entry.get("hooks", []):
                    check(f"{rel}: hook has a type", "type" in hook)
                    cmd = hook.get("command", "")
                    # The repo stores the template; the installer substitutes
                    # a platform-specific command at install time.
                    check(f"{rel}: command is an unsubstituted placeholder",
                          cmd.startswith("__OMA_") and cmd.endswith("__"),
                          f"command={cmd!r}")


def check_personas():
    print("\npersonas")
    persona_files = sorted((HOME / "personas").glob("*.toml"))
    check("at least one persona is shipped", len(persona_files) > 0)
    if tomllib is None:
        print("  skip TOML parsing (needs Python 3.11+)")
        return
    for path in persona_files:
        rel = path.relative_to(REPO)
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as exc:
            bad(f"{rel}: is valid TOML", str(exc))
            continue
        ok(f"{rel}: is valid TOML")
        check(f"{rel}: has description", bool(data.get("description")))
        check(f"{rel}: has instructions", bool(data.get("instructions")))


def check_config_snippet():
    print("\nconfig snippet")
    path = REPO / "config" / "config.toml.snippet"
    check("config.toml.snippet exists", path.is_file())
    if not path.is_file() or tomllib is None:
        return
    try:
        tomllib.loads(path.read_text(encoding="utf-8"))
        ok("config.toml.snippet is valid TOML")
    except tomllib.TOMLDecodeError as exc:
        bad("config.toml.snippet is valid TOML", str(exc))


def check_installer_versions():
    print("\ninstaller agreement")
    sh = (REPO / "install.sh").read_text(encoding="utf-8")
    ps = (REPO / "install.ps1").read_text(encoding="utf-8")
    sh_ver = re.search(r'OMA_VERSION="([^"]+)"', sh)
    ps_ver = re.search(r"\$OmaVersion\s*=\s*'([^']+)'", ps)
    check("install.sh declares a version", sh_ver is not None)
    check("install.ps1 declares a version", ps_ver is not None)
    if sh_ver and ps_ver:
        check("installers agree on the version", sh_ver.group(1) == ps_ver.group(1),
              f"install.sh={sh_ver.group(1)} install.ps1={ps_ver.group(1)}")
        check("version is semver-shaped",
              re.fullmatch(r"\d+\.\d+\.\d+", sh_ver.group(1)) is not None,
              f"got {sh_ver.group(1)!r}")

        # The generator stamps its own version into every snippet it prints, so
        # a missed bump there is a wrong number in output people paste into a
        # config and keep. Four copies of a version string is three chances to
        # drift; this is the check that makes them one.
        for name, pattern in (
            ("tools/gen-roles.sh", r'OMA_VERSION="([^"]+)"'),
            ("tools/gen-roles.ps1", r"\$OmaVersion\s*=\s*'([^']+)'"),
            ("tools/doctor.sh", r'OMA_VERSION="([^"]+)"'),
            ("tools/doctor.ps1", r"\$OmaVersion\s*=\s*'([^']+)'"),
        ):
            found = re.search(pattern, (REPO / name).read_text(encoding="utf-8"))
            check(f"{name} declares a version", found is not None)
            if found:
                check(f"{name} agrees with the installers",
                      found.group(1) == sh_ver.group(1),
                      f"{name}={found.group(1)} install.sh={sh_ver.group(1)}")

    # Both installers prune the same directories on uninstall. A skill added
    # to one list and not the other leaves an empty dir behind on one OS.
    sh_dirs = re.search(r"for d in ([^;]+); do", sh)
    ps_dirs = re.search(r"foreach \(\$d in ([^)]+)\) \{", ps)
    if sh_dirs and ps_dirs:
        a = {p.strip().replace("\\", "/") for p in sh_dirs.group(1).split()}
        b = {p.strip().strip("'").replace("\\", "/") for p in ps_dirs.group(1).split(",")}
        check("installers prune the same directories", a == b,
              f"only in install.sh: {sorted(a - b)}; only in install.ps1: {sorted(b - a)}")

    # Every shipped skill must be in the prune list, or uninstall leaves it.
    if sh_dirs:
        pruned = {p.strip() for p in sh_dirs.group(1).split()}
        for d in sorted(x for x in (HOME / "skills").iterdir() if x.is_dir()):
            check(f"uninstall prunes skills/{d.name}", f"skills/{d.name}" in pruned,
                  "add it to the prune list in both installers")


def check_readme(agent_names, skill_names):
    print("\nREADME coverage")
    readme = (REPO / "README.md").read_text(encoding="utf-8")
    for name in agent_names:
        check(f"README mentions agent {name}", f"`{name}`" in readme,
              "shipped but undocumented")
    for name in skill_names:
        check(f"README mentions skill {name}", f"/{name}" in readme,
              "shipped but undocumented")

    # A literal tab where `\t` was meant. This has happened more than once,
    # always the same way: a Windows path like `.\tools\doctor.ps1` written
    # through something that interprets the escape, leaving `.` + TAB +
    # `ools\doctor.ps1`. It renders as innocent whitespace and passes every
    # other check here, and the command it documents cannot be copied.
    tab_lines = [i for i, line in enumerate(readme.splitlines(), 1) if "\t" in line]
    check("README contains no literal tabs", not tab_lines,
          f"tabs on line(s) {tab_lines} -- a mangled \\t in a Windows path?")


def main():
    print("oh-my-axon structure validation")
    agent_names = check_agents()
    skill_names = check_skills()
    check_hooks()
    check_personas()
    check_config_snippet()
    check_installer_versions()
    check_readme(agent_names, skill_names)
    print(f"\n{checks} checks, {failures} failed")
    if failures:
        return 1
    print("structure validation passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
