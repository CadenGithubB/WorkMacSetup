#!/usr/bin/python3
"""Prepare a staged ad-hoc Work Mac Setup build for release, then check privacy.

--prepare strips the executables, removes build-machine plist keys, and
re-signs every component ad hoc with the Hardened Runtime. --archive writes a
deterministic ZIP with no extended attributes, resource forks, or local
timestamps. Only run --prepare on a disposable staged copy.
"""
import argparse
import os
import plistlib
import re
import stat
import subprocess
import zipfile
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
ENTITLEMENTS = REPO / "Resources/DockDragHelper.entitlements"
DOCK_HELPER = "Contents/Helpers/Work Mac Dock Helper.app"
PROFILE_HELPER = "Contents/Resources/chrome-profile-helper"
BUILD_KEYS = {
    "BuildMachineOSBuild", "DTCompiler", "DTPlatformBuild", "DTPlatformName",
    "DTPlatformVersion", "DTSDKBuild", "DTSDKName", "DTXcode", "DTXcodeBuild",
}
ARTIFACT_SUFFIXES = {".log", ".xcactivitylog", ".xcresult", ".crash", ".ips", ".dSYM"}
UNSAFE_ENTITLEMENTS = ("com.apple.security.get-task-allow",
                       "com.apple.security.cs.allow-", "com.apple.security.cs.disable-")


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def private_markers():
    """Byte patterns for a real local path. The shipped setup script builds
    paths from $USER-style variables and the palette checks the bare
    /var/folders/ prefix; neither names a user, so neither matches here."""
    markers = [
        rb"/Users/[A-Za-z0-9._-]+/", rb"/home/[A-Za-z0-9._-]+/",
        rb"/Volumes/", rb"/private/tmp/", rb"/var/folders/[0-9a-z_]{2}/",
    ]
    for path in (os.path.expanduser("~"), str(REPO)):
        markers.append(re.escape(path.encode()))
    return [re.compile(marker) for marker in markers]


def bundle_executable(bundle):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    return bundle / "Contents/MacOS" / info["CFBundleExecutable"]


def components(app):
    """(signing target, executable, entitlements) innermost first, so each
    outer seal covers already-finalized inner code."""
    helper = app / DOCK_HELPER
    return [
        (app / PROFILE_HELPER, app / PROFILE_HELPER, None),
        (helper, bundle_executable(helper), ENTITLEMENTS),
        (app, bundle_executable(app), None),
    ]


def architectures(executable):
    archs = run("/usr/bin/lipo", "-archs", str(executable)).stdout.decode().split()
    if not archs:
        raise ValueError("No executable architectures: " + str(executable))
    return archs


def signature_lines(target, arch):
    return run("/usr/bin/codesign", "-dv", "--arch", arch, str(target)).stderr.decode().splitlines()


def entitlements_of(target, arch):
    data = run("/usr/bin/codesign", "-d", "--arch", arch, "--entitlements", ":-", str(target)).stdout
    return plistlib.loads(data) if data.strip() else {}


def require_adhoc(app):
    # Refuse to replace a certificate signature with an ad-hoc one.
    for target, executable, _ in components(app):
        for arch in architectures(executable):
            if "Signature=adhoc" not in signature_lines(target, arch):
                raise ValueError("Release preparation requires an ad-hoc input build: " + target.name)


def verify_signatures(app):
    for target, executable, entitlement_file in components(app):
        run("/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(target))
        expected = plistlib.loads(entitlement_file.read_bytes()) if entitlement_file else {}
        for arch in architectures(executable):
            directory = [line for line in signature_lines(target, arch) if line.startswith("CodeDirectory")]
            if not any("runtime" in line for line in directory):
                raise ValueError(f"Hardened Runtime is missing for {arch}: {target.name}")
            found = entitlements_of(target, arch)
            for key in found:
                if key.startswith(UNSAFE_ENTITLEMENTS):
                    raise ValueError(f"Unsafe entitlement {key} for {arch}: {target.name}")
            if found != expected:
                raise ValueError(f"Unexpected entitlements for {arch}: {target.name}")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))


def verify_privacy(app):
    markers = private_markers()
    for item in app.rglob("*"):
        relative = item.relative_to(app)
        if item.is_symlink():
            raise ValueError("Unexpected symlink in staged app: " + str(relative))
        if item.suffix in ARTIFACT_SUFFIXES or item.name == ".DS_Store":
            raise ValueError("Local diagnostic artifact in staged app: " + str(relative))
        if not item.is_file():
            continue
        data = item.read_bytes()
        if any(marker.search(data) for marker in markers):
            raise ValueError("Local filesystem path in staged app: " + str(relative))
        if item.name == "Info.plist":
            info = plistlib.loads(data)
            if BUILD_KEYS.intersection(info):
                raise ValueError("Build-machine metadata in staged app: " + str(relative))


def prepare(app):
    require_adhoc(app)
    for target, executable, entitlement_file in components(app):
        run("/usr/bin/strip", "-S", str(executable))
        if target.is_dir():
            plist = target / "Contents/Info.plist"
            info = plistlib.loads(plist.read_bytes())
            if BUILD_KEYS.intersection(info):
                for key in BUILD_KEYS:
                    info.pop(key, None)
                plist.write_bytes(plistlib.dumps(info))
        arguments = ["/usr/bin/codesign", "--force", "--sign", "-",
                     "--options", "runtime", "--timestamp=none"]
        if entitlement_file:
            arguments += ["--entitlements", str(entitlement_file)]
        run(*arguments, str(target))
    verify_signatures(app)
    verify_privacy(app)


def archive(app, destination):
    verify_privacy(app)
    # Write file contents explicitly. Filesystem copy APIs can reattach local
    # provenance even when asked to omit xattrs; ZIP entries have none here.
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as output:
        for item in [app] + sorted(app.rglob("*")):
            name = str(item.relative_to(app.parent))
            directory = item.is_dir()
            if directory:
                name += "/"
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            mode = (stat.S_IFDIR | 0o755) if directory else (
                stat.S_IFREG | (0o755 if item.stat().st_mode & 0o111 else 0o644))
            entry.external_attr = mode << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(entry, b"" if directory else item.read_bytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--archive", type=Path)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    if not args.app.is_dir() or args.app.is_symlink():
        parser.error("Expected a real app directory.")
    if args.prepare:
        prepare(args.app)
    else:
        verify_signatures(args.app)
        verify_privacy(args.app)
    if args.archive:
        archive(args.app, args.archive)


if __name__ == "__main__":
    main()
