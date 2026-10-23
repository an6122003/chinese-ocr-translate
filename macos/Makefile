# HanLens — macOS build
#   make            build HanLens.app (Release) into build/
#   make install    build, install to /Applications and launch
#   make test       run the HanziKit unit tests
#   make data       (re)build the offline dictionary Data/hanzi.sqlite
#   make project    generate HanLens.xcodeproj for working in Xcode

APP_NAME     := HanLens
BUILD_DIR    := build
DERIVED      := $(BUILD_DIR)/DerivedData
PRODUCT      := $(DERIVED)/Build/Products/Release/$(APP_NAME).app
APP          := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR  ?= /Applications
# First valid "Apple Development" identity (a stable signature keeps macOS permissions across rebuilds).
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning | grep "Apple Development" | grep -v REVOKED | head -1 | awk '{print $$2}')
PYTHON       := python3 -I
LSREGISTER   := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all app install run test data project clean distclean

all: app

data: Data/hanzi.sqlite

Data/hanzi.sqlite: scripts/build_dictionary.py Data/sources.lock.json $(wildcard Data/vendor/*)
	$(PYTHON) scripts/fetch_sources.py
	$(PYTHON) scripts/build_dictionary.py

project: HanLens.xcodeproj

HanLens.xcodeproj: project.yml
	xcodegen generate --quiet

app: data project
	xcodebuild -project HanLens.xcodeproj -scheme $(APP_NAME) -configuration Release \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' \
		CODE_SIGNING_ALLOWED=NO build -quiet
	rm -rf $(APP) && ditto $(PRODUCT) $(APP)
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		codesign --force --deep --options runtime --timestamp=none --sign "$(SIGN_IDENTITY)" $(APP) && \
		echo "Signed with $(SIGN_IDENTITY)"; \
	else \
		codesign --force --deep --sign - $(APP) && \
		echo "No Apple Development identity found — ad-hoc signed (macOS may ask for permissions again after each build)"; \
	fi
	@echo "Built $(APP)"

install: app
	-@pkill -x $(APP_NAME) 2>/dev/null && sleep 1; true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	ditto $(APP) "$(INSTALL_DIR)/$(APP_NAME).app"
	@# ditto keeps the build's dates; a fresh one makes Finder and the Dock reload the icon.
	touch "$(INSTALL_DIR)/$(APP_NAME).app" "$(INSTALL_DIR)/$(APP_NAME).app/Contents/Info.plist"
	@# Only the installed copy should answer hanlens:// links and the Services menu.
	-@$(LSREGISTER) -u $(APP) $(PRODUCT) $(DERIVED)/Build/Products/Debug/$(APP_NAME).app 2>/dev/null; true
	$(LSREGISTER) -f "$(INSTALL_DIR)/$(APP_NAME).app"
	/System/Library/CoreServices/pbs -update 2>/dev/null || true
	open "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

# A drag-to-Applications disk image for sharing: build/HanLens-<version>.dmg
VERSION := $(shell sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
DMG     := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg

dmg: app
	rm -rf $(BUILD_DIR)/dmg $(DMG) && mkdir -p $(BUILD_DIR)/dmg
	ditto $(APP) $(BUILD_DIR)/dmg/$(APP_NAME).app
	ln -s /Applications $(BUILD_DIR)/dmg/Applications
	cp scripts/dmg-readme.txt "$(BUILD_DIR)/dmg/How to open HanLens.txt"
	hdiutil create -volname "$(APP_NAME) $(VERSION)" -srcfolder $(BUILD_DIR)/dmg -fs HFS+ -format UDZO -ov $(DMG) -quiet
	@if [ -n "$(SIGN_IDENTITY)" ]; then codesign --force --sign "$(SIGN_IDENTITY)" $(DMG); fi
	@echo "Built $(DMG)"

run: app
	-@pkill -x $(APP_NAME) 2>/dev/null; true
	open $(APP)

test: data
	cd HanziKit && swift test

clean:
	rm -rf $(BUILD_DIR) HanLens.xcodeproj

distclean: clean
	rm -rf Data/cache Data/hanzi.sqlite
