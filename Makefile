ENT  := Resources/entitlements.plist
BIN  := .build/release
APP  := FFTray.app
VER  ?= $(shell sed -n 's/.*string = "\(.*\)".*/\1/p' Sources/FFCore/Version.swift)
DMG  := ff400ctl-$(VER).dmg

.PHONY: all cli app test e2e hwtest install clean universal dmg print-version

print-version:
	@echo $(VER)

all: cli app

cli:
	swift build -c release --product ffctl
	codesign -s - --force --entitlements $(ENT) $(BIN)/ffctl

app:
	swift build -c release --product FFTray
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN)/FFTray $(APP)/Contents/MacOS/FFTray
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	mkdir -p $(APP)/Contents/Resources && cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	plutil -replace CFBundleShortVersionString -string $(VER) $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string $$(git rev-list --count HEAD) $(APP)/Contents/Info.plist
	codesign -s - --force --entitlements $(ENT) $(APP)

# Universal release build (x86_64 + arm64 via lipo; works with CLT only).
universal:
	swift build -c release --triple x86_64-apple-macosx13 --product ffctl
	swift build -c release --triple x86_64-apple-macosx13 --product FFTray
	swift build -c release --triple arm64-apple-macosx13 --product ffctl
	swift build -c release --triple arm64-apple-macosx13 --product FFTray
	mkdir -p .build/universal
	lipo -create .build/x86_64-apple-macosx/release/ffctl \
		.build/arm64-apple-macosx/release/ffctl -output .build/universal/ffctl
	lipo -create .build/x86_64-apple-macosx/release/FFTray \
		.build/arm64-apple-macosx/release/FFTray -output .build/universal/FFTray
	mkdir -p $(APP)/Contents/MacOS
	cp .build/universal/FFTray $(APP)/Contents/MacOS/FFTray
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	mkdir -p $(APP)/Contents/Resources && cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	plutil -replace CFBundleShortVersionString -string $(VER) $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string $$(git rev-list --count HEAD) $(APP)/Contents/Info.plist
	codesign -s - --force --entitlements $(ENT) .build/universal/ffctl
	codesign -s - --force --entitlements $(ENT) $(APP)

# Release DMG: app + Applications shortcut + CLI + INSTALL.txt
dmg: universal
	rm -rf .build/dmg
	mkdir -p .build/dmg
	cp -R $(APP) .build/dmg/
	cp .build/universal/ffctl .build/dmg/ffctl
	ln -sfn /Applications .build/dmg/Applications
	printf '%s\n' \
		"ff400ctl $(VER) — install" "" \
		"1. Drag FFTray.app onto the Applications shortcut (menu-bar mixer UI)." \
		"2. For the command-line tool:  sudo cp ffctl /usr/local/bin/" "" \
		"First launch: the app isn't notarized, so Gatekeeper blocks it." \
		"Right-click FFTray.app -> Open, or approve via System Settings ->" \
		"Privacy & Security -> Open Anyway, or clear quarantine:" \
		"    xattr -dr com.apple.quarantine /Applications/FFTray.app" \
		"    xattr -d com.apple.quarantine /usr/local/bin/ffctl" "" \
		"Both binaries are ad-hoc signed and claim" \
		"com.apple.developer.driverkit.userclient-access for net.asfw.driver." \
		"Verified on the author's Mac (custom SIP config, OCLP); on a" \
		"stock-security Mac macOS may refuse to run a binary claiming that" \
		"restricted entitlement without a provisioning profile — untested," \
		"reports welcome. Planned fix: ASFW adopting" \
		"com.apple.developer.driverkit.allow-any-userclient-access." \
		"Docs: README.md, CLI.md." \
		> .build/dmg/INSTALL.txt
	hdiutil create -volname "ff400ctl $(VER)" -srcfolder .build/dmg -ov -format UDZO $(DMG)

test:
	swift run fftests

# CLI end-to-end: real ffctl binary against a fake device (no hardware).
e2e:
	swift build --product ffctl
	bash scripts/e2e-cli.sh

# Hardware smoke test — only when a powered FF400 is connected.
# The user-client access entitlement is required even for ad-hoc debug.
hwtest:
	swift build --product ffctl
	codesign -s - --force --entitlements $(ENT) .build/debug/ffctl
	bash scripts/hardware-smoke.sh

install: all
	cp $(BIN)/ffctl /usr/local/bin/ffctl
	cp -R $(APP) /Applications/

clean:
	swift package clean
	rm -rf $(APP)
