ENT  := Resources/entitlements.plist
BIN  := .build/release
APP  := FFTray.app
VER  ?= 0.5.0
DMG  := ff400ctl-$(VER).dmg

.PHONY: all cli app test install clean universal dmg

all: cli app

cli:
	swift build -c release --product ffctl
	codesign -s - --force --entitlements $(ENT) $(BIN)/ffctl

app:
	swift build -c release --product FFTray
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN)/FFTray $(APP)/Contents/MacOS/FFTray
	cp Resources/Info.plist $(APP)/Contents/Info.plist
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
		"Both binaries are ad-hoc signed with the net.asfw.driver userclient" \
		"entitlement, so they can talk to the ASFW driver. Docs: README.md, CLI.md." \
		> .build/dmg/INSTALL.txt
	hdiutil create -volname "ff400ctl $(VER)" -srcfolder .build/dmg -ov -format UDZO $(DMG)

test:
	swift run fftests

install: all
	cp $(BIN)/ffctl /usr/local/bin/ffctl
	cp -R $(APP) /Applications/

clean:
	swift package clean
	rm -rf $(APP)
