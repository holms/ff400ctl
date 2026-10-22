ENT  := Resources/entitlements.plist
BIN  := .build/release
APP  := FFTray.app

.PHONY: all cli app test install clean

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

test:
	swift run fftests

install: all
	cp $(BIN)/ffctl /usr/local/bin/ffctl
	cp -R $(APP) /Applications/

clean:
	swift package clean
	rm -rf $(APP)
