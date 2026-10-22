"""Build Info.plist from one release line, with optional signed updates."""
import os
import plistlib
import re
import subprocess
from pathlib import Path

base = Path("VERSION").read_text().strip()
count = subprocess.check_output(["git", "rev-list", "--count", "HEAD"], text=True).strip()
version = os.environ.get("VERSION", f"{base}.{count}")
assert re.fullmatch(r"\d+\.\d+\.\d+", version), "VERSION must be major.minor.patch"
build = os.environ.get("BUILD_NUMBER", count)
assert build.isdigit(), "BUILD_NUMBER must be numeric"
info = {
    "CFBundleExecutable": "MacCAD", "CFBundleIdentifier": "xyz.ckakkar.maccad",
    "CFBundleName": "MacCAD", "CFBundleDisplayName": "MacCAD",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
    "CFBundleVersion": build, "LSMinimumSystemVersion": "14.0",
    "MacCADSourceRevision": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
    "CFBundleIconFile": "AppIcon", "NSSupportsAutomaticTermination": False,
    "NSHumanReadableCopyright": "mac-cad contributors · GPL-3.0-or-later",
    "NSLocalNetworkUsageDescription": "MacCAD looks for printers and plotters on your network when you print a drawing.",
    "CFBundleDocumentTypes": [{
        "CFBundleTypeName": "MacCAD Drawing", "CFBundleTypeRole": "Editor",
        "NSDocumentClass": "MacCAD.DrawingDocument", "LSHandlerRank": "Owner",
        "LSItemContentTypes": ["xyz.ckakkar.maccad.drawing"],
        "CFBundleTypeExtensions": ["maccad"],
    }, {
        "CFBundleTypeName": "CAD Exchange Drawing", "CFBundleTypeRole": "Viewer",
        "LSHandlerRank": "Alternate", "LSItemContentTypes": ["com.autodesk.dxf", "com.autodesk.dwg"],
        "CFBundleTypeExtensions": ["dxf", "dwg"],
    }],
    "UTExportedTypeDeclarations": [{
        "UTTypeIdentifier": "xyz.ckakkar.maccad.drawing", "UTTypeDescription": "MacCAD Drawing",
        "UTTypeConformsTo": ["public.json"], "UTTypeTagSpecification": {"public.filename-extension": ["maccad"]},
    }],
    "UTImportedTypeDeclarations": [
        {"UTTypeIdentifier": f"com.autodesk.{ext}", "UTTypeConformsTo": ["public.data"], "UTTypeTagSpecification": {"public.filename-extension": [ext]}}
        for ext in ["dxf", "dwg"]
    ],
}
key = (os.environ.get("SPARKLE_PUBLIC_KEY") or Path("config/SparklePublicKey").read_text()).strip()
if key:
    import base64
    assert len(base64.b64decode(key, validate=True)) == 32, "Invalid Sparkle public key"
    info.update({
        "SUPublicEDKey": key,
        "SUFeedURL": "https://github.com/ckakkar/mac-cad/releases/latest/download/appcast.xml",
        "SUScheduledCheckInterval": 3600, "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": False, "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
    })
Path("build/MacCAD.app/Contents/Info.plist").write_bytes(plistlib.dumps(info))
