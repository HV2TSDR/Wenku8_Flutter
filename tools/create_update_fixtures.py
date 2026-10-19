#!/usr/bin/env python3
"""Build tiny debug-signed APKs for the isolated Android update fixtures.

Build integration_test/update_install_probe.dart as debug 0.3.3+35 first. Copy
these APKs into the probe's files/update-fixtures directory using adb run-as.
Never install a fixture over the release application: its ID is render_probe.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--debug-keystore", type=Path,
                        default=Path.home() / ".android/debug.keystore")
    args = parser.parse_args()
    tools = args.sdk / "build-tools/36.1.0"
    android = args.sdk / "platforms/android-36/android.jar"
    args.output.mkdir(parents=True, exist_ok=True)
    for filename, package, version, build in [
        ("36", "org.mewx.wenku8_flutter.render_probe", "0.3.4", 36),
        ("37", "org.mewx.wenku8_flutter.render_probe", "0.3.5", 37),
        ("other", "org.mewx.wenku8_flutter.other_fixture", "0.3.4", 36),
    ]:
        with tempfile.TemporaryDirectory(prefix="wenku-update-fixture-") as work:
            manifest = Path(work) / "AndroidManifest.xml"
            manifest.write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="{package}" android:versionCode="{build}" android:versionName="{version}">
    <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="36" />
    <application android:label="文库更新验证" android:hasCode="false" />
</manifest>''')
            unsigned = Path(work) / "unsigned.apk"
            aligned = Path(work) / "aligned.apk"
            result = args.output / f"{filename}.apk"
            subprocess.run([str(tools / "aapt"), "package", "-f", "-M", str(manifest),
                            "-I", str(android), "-F", str(unsigned)], check=True)
            subprocess.run([str(tools / "zipalign"), "-f", "4", str(unsigned), str(aligned)], check=True)
            subprocess.run([str(tools / "apksigner"), "sign", "--ks", str(args.debug_keystore),
                            "--ks-pass", "pass:android", "--key-pass", "pass:android", "--ks-key-alias",
                            "androiddebugkey", "--out", str(result), str(aligned)], check=True)
            print(f"{result}: {package} {version}+{build}")


if __name__ == "__main__":
    main()
