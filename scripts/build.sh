#!/bin/sh
# Builds build.noindex/Cosmopolitan.app (and its .dSYM). The folder ends in .noindex so Spotlight skips it: every work folder
# with a build used to show up as one more "Cosmopolitan" in Launchpad (five on 2026-10-30). Install or release from there.
set -e; cd "$(dirname "$0")/.."   # repo root (scripts/ lives one level down)
rm -rf build.noindex/Cosmopolitan.app; mkdir -p build.noindex/Cosmopolitan.app/Contents/MacOS build.noindex/Cosmopolitan.app/Contents/Resources build.noindex/Cosmopolitan.app/Contents/Frameworks
# Sparkle (MIT) for auto-updates: framework embedded, EdDSA public key in Info.plist, feed URL set in release.sh's appcast.
cp -R Sparkle/Sparkle.framework build.noindex/Cosmopolitan.app/Contents/Frameworks/
# Native C++ module (Sources/Native): compiled once per build, linked into the Swift binary through the bridging header.
# Oldest macOS the app runs on (matches Package.swift). Without it the compiler targets the build Mac's own OS, so a build on macOS 27 refused to open on 26 (Tahoe).
MIN=26.0; export MACOSX_DEPLOYMENT_TARGET=$MIN
mkdir -p build; echo '["AppIntent","EntityQuery","EntityStringQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider"]' > build/appintents-protocols.json
for c in Sources/Native/*.cpp; do clang++ -mmacosx-version-min=$MIN -std=c++17 -O2 -Wall -Wextra -Werror -c "$c" -o "build/$(basename "${c%.cpp}").o"; done
# -g keeps debug info; dsymutil moves it into a separate Cosmopolitan.app.dSYM (shipped next to releases, never inside the app).
swiftc -target "$(uname -m)-apple-macos$MIN" -parse-as-library -O -g -wmo -framework AppIntents -emit-const-values-path build/Cosmopolitan.swiftconstvalues -Xfrontend -const-gather-protocols-file -Xfrontend build/appintents-protocols.json -import-objc-header Sources/Native/cosmo_native.h -F Sparkle -framework Sparkle -framework IOKit -Xlinker -rpath -Xlinker @executable_path/../Frameworks -lc++ -o build.noindex/Cosmopolitan.app/Contents/MacOS/Cosmopolitan $(find Sources -name '*.swift' | sort) build/*.o
# App Intents (item 37): Shortcuts and Spotlight read Contents/Resources/Metadata.appintents, extracted here from the compiler's constant values.
TC=$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")"); find "$PWD/Sources" -name '*.swift' | sort > build/swift-sources.txt; echo "$PWD/build/Cosmopolitan.swiftconstvalues" > build/swift-consts.txt
xcrun appintentsmetadataprocessor --output build.noindex/Cosmopolitan.app/Contents/Resources --toolchain-dir "$TC" --module-name Cosmopolitan --sdk-root "$(xcrun --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" --platform-family macOS --deployment-target $MIN --target-triple "$(uname -m)-apple-macos$MIN" \
  --source-file-list build/swift-sources.txt --swift-const-vals-list build/swift-consts.txt --binary-file build.noindex/Cosmopolitan.app/Contents/MacOS/Cosmopolitan \
  --dependency-file build/appintents.d --stringsdata-file build/appintents.stringsdata --no-app-shortcuts-localization --force 2>&1 | grep -E 'Writing|error' || true
mv -f Cosmopolitan-[0-9]*.swiftmodule Cosmopolitan-[0-9]*.swiftdoc Cosmopolitan-[0-9]*.abi.json Cosmopolitan-[0-9]*.swiftsourceinfo build/ 2>/dev/null || true   # side outputs of the constant-value extraction (whole-module); nothing links against them
dsymutil build.noindex/Cosmopolitan.app/Contents/MacOS/Cosmopolitan -o build.noindex/Cosmopolitan.app.dSYM 2>/dev/null
strip -S build.noindex/Cosmopolitan.app/Contents/MacOS/Cosmopolitan 2>/dev/null   # app stays small; symbols live in the dSYM
PUBKEY=$(cat Sparkle/public-key.txt 2>/dev/null); FEED=${COSMO_FEED_URL:-https://github.com/cyber-prinzesse/Cosmopolitan/releases/latest/download/appcast.xml}
cp AppIcon.icns build.noindex/Cosmopolitan.app/Contents/Resources/  # built once from icon.png: sips -z … + iconutil -c icns
cp TERMS.txt THIRD_PARTY_NOTICES.md README.md build.noindex/Cosmopolitan.app/Contents/Resources/   # shown on first run / referenced from the UI
cp -R Resources/fonts build.noindex/Cosmopolitan.app/Contents/Resources/   # Instrument Sans (OFL), registered via ATSApplicationFontsPath below
cp Resources/cosmos-glass-1024.png build.noindex/Cosmopolitan.app/Contents/Resources/   # preparing-bottle window (outline drawn in SwiftUI)
# Engine add-on (x86_64, loaded by Wine's Mac driver, not by the app): steam.exe gets no Dock icon of its own (NoDockAddon.swift).
clang -arch x86_64 -mmacosx-version-min=10.15 -dynamiclib -fobjc-arc -O2 -Wall -Werror -framework AppKit -install_name @loader_path/cosmo_nodock.dylib -o build.noindex/Cosmopolitan.app/Contents/Resources/cosmo_nodock.dylib EngineAddon/cosmo_nodock.m
codesign --force --sign - build.noindex/Cosmopolitan.app/Contents/Resources/cosmo_nodock.dylib
cp Resources/cosmo_exeIcon.icns build.noindex/Cosmopolitan.app/Contents/Resources/   # every Wine 10 Dock tile (cosmo_nodock loads it)
# Dock-label dispatcher (x86_64 like Wine): Cosmo starts Wine through it; children re-enter via WINELOADER and exec bin/<Name>.
clang -arch x86_64 -mmacosx-version-min=10.15 -O2 -Wall -Werror -o build.noindex/Cosmopolitan.app/Contents/Resources/cosmo_wineloader EngineAddon/cosmo_wineloader.c
codesign --force --sign - build.noindex/Cosmopolitan.app/Contents/Resources/cosmo_wineloader
cp Resources/netprobe.exe build.noindex/Cosmopolitan.app/Contents/Resources/   # .NET probe run once per bottle (source: Resources/netprobe.cs)
cat > build.noindex/Cosmopolitan.app/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleName</key><string>Cosmopolitan</string><key>CFBundleExecutable</key><string>Cosmopolitan</string>
<key>CFBundleIdentifier</key><string>local.cosmopolitan</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string><key>NSHighResolutionCapable</key><true/><key>ATSApplicationFontsPath</key><string>fonts</string>
<key>LSMinimumSystemVersion</key><string>$MIN</string><key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>CFBundleShortVersionString</key><string>${COSMO_VERSION:-1.0}</string><key>CFBundleVersion</key><string>${COSMO_BUILD:-$(date +%Y%m%d%H%M)}</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>local.cosmopolitan</string><key>CFBundleURLSchemes</key><array><string>cosmopolitan</string></array></dict></array>
<key>SUFeedURL</key><string>$FEED</string><key>SUPublicEDKey</key><string>$PUBKEY</string><key>SUEnableAutomaticChecks</key><true/></dict></plist>
P
codesign --force --sign - build.noindex/Cosmopolitan.app
