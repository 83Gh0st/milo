"""Wire Play release signing into the `flutter create`-generated Gradle file.

`flutter create` ships no release signing config (release builds use the debug
key). The release workflow calls this after writing android/key.properties from
GitHub secrets; it adds a `signingConfigs.release` block fed by that file and
points the release build type at it.

Fails loudly (exit 2) when the Flutter Gradle template drifts, so a silent
mis-sign never ships. Run from the repo root::

    python3 tools/wire_android_signing.py
"""

import pathlib
import sys

GRADLE = pathlib.Path("android/app/build.gradle")


def main() -> int:
    if not GRADLE.exists():
        print("android template changed (no app/build.gradle): update the signing patch")
        return 2
    t = GRADLE.read_text()
    if "signingConfigs.debug" not in t or "keystoreProperties" in t:
        print("android template changed: update the signing patch")
        return 2
    t = t.replace(
        "android {",
        "def keystoreProperties = new Properties()\n"
        "def keystorePropertiesFile = rootProject.file('key.properties')\n"
        "if (keystorePropertiesFile.exists()) { keystoreProperties.load(new FileInputStream(keystorePropertiesFile)) }\n"
        "android {",
        1,
    )
    t = t.replace("signingConfig signingConfigs.debug", "signingConfig signingConfigs.release", 1)
    t = t.replace(
        "    buildTypes {",
        "    signingConfigs {\n"
        "        release {\n"
        "            keyAlias keystoreProperties['keyAlias']\n"
        "            keyPassword keystoreProperties['keyPassword']\n"
        "            storeFile file(keystoreProperties['storeFile'])\n"
        "            storePassword keystoreProperties['storePassword']\n"
        "        }\n"
        "    }\n"
        "    buildTypes {",
        1,
    )
    if "signingConfigs.release" not in t:
        print("signing patch did not apply: update the script")
        return 2
    GRADLE.write_text(t)
    print("release signing wired")
    return 0


if __name__ == "__main__":
    sys.exit(main())
