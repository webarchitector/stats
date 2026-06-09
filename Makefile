APP = Stats
BUNDLE_ID = eu.exelban.$(APP)

BUILD_PATH = $(PWD)/build
APP_PATH = "$(BUILD_PATH)/$(APP).app"
ZIP_PATH = "$(BUILD_PATH)/$(APP).zip"

.SILENT: archive notarize sign prepare-dmg prepare-dSYM clean next-version check history disk smc local
.PHONY: build archive notarize sign prepare-dmg prepare-dSYM clean next-version check history open smc local

build: clean next-version archive notarize sign prepare-dmg prepare-dSYM open

# --- MAIN WORLFLOW FUNCTIONS --- #

archive: clean
	osascript -e 'display notification "Exporting application archive..." with title "Build the Stats"'
	echo "Exporting application archive..."

	xcodebuild \
  		-scheme $(APP) \
  		-destination 'platform=OS X,arch=x86_64' \
  		-configuration Release archive \
  		-archivePath $(BUILD_PATH)/$(APP).xcarchive

	echo "Application built, starting the export archive..."

	xcodebuild -exportArchive \
  		-exportOptionsPlist "$(PWD)/exportOptions.plist" \
  		-archivePath $(BUILD_PATH)/$(APP).xcarchive \
  		-exportPath $(BUILD_PATH)

	ditto -c -k --keepParent $(APP_PATH) $(ZIP_PATH)

	echo "Project archived successfully"

notarize:
	osascript -e 'display notification "Submitting app for notarization..." with title "Build the Stats"'
	echo "Submitting app for notarization..."

	xcrun notarytool submit --keychain-profile "AC_PASSWORD" --wait $(ZIP_PATH)

	echo "Stats successfully notarized"

sign:
	osascript -e 'display notification "Stampling the Stats..." with title "Build the Stats"'
	echo "Going to staple an application..."

	xcrun stapler staple $(APP_PATH)
	spctl -a -t exec -vvv $(APP_PATH)

	osascript -e 'display notification "Stats successfully stapled" with title "Build the Stats"'
	echo "Stats successfully stapled"

prepare-dmg:
	if [ ! -d $(PWD)/create-dmg ]; then \
	    git clone https://github.com/create-dmg/create-dmg; \
	fi

	./create-dmg/create-dmg \
	    --volname $(APP) \
	    --background "./Stats/Supporting Files/background.png" \
	    --window-pos 200 120 \
	    --window-size 500 320 \
	    --icon-size 80 \
	    --icon "Stats.app" 125 175 \
	    --hide-extension "Stats.app" \
	    --app-drop-link 375 175 \
	    --no-internet-enable \
	    $(PWD)/$(APP).dmg \
	    $(APP_PATH)

	rm -rf ./create-dmg

prepare-dSYM:
	echo "Zipping dSYMs..."
	cd $(BUILD_PATH)/Stats.xcarchive/dSYMs && zip -r $(PWD)/dSYMs.zip .
	echo "Created zip with dSYMs"

# --- HELPERS --- #

clean:
	rm -rf $(BUILD_PATH)
	if [ -a $(PWD)/dSYMs.zip ]; then rm $(PWD)/dSYMs.zip; fi;
	if [ -a $(PWD)/Stats.dmg ]; then rm $(PWD)/Stats.dmg; fi;

next-version:
	versionNumber=$$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(PWD)/Stats/Supporting Files/Info.plist") ;\
	echo "Actual version is: $$versionNumber" ;\
	versionNumber=$$((versionNumber + 1)) ;\
	echo "Next version is: $$versionNumber" ;\
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$versionNumber" "$(PWD)/Stats/Supporting Files/Info.plist" ;\

check:
	xcrun notarytool log 2d0045cc-8f0d-4f4c-ba6f-728895fd064a --keychain-profile "AC_PASSWORD"

history:
	xcrun notarytool history --keychain-profile "AC_PASSWORD"

open:
	osascript -e 'display notification "Stats signed and ready for distribution" with title "Build the Stats"'
	echo "Opening working folder..."
	open $(PWD)

smc:
	$(MAKE) --directory=./smc
	open $(PWD)/smc

# --- LOCAL DEV BUILD (no notarization, ad-hoc sign, install to /Applications) ---
local: clean
	xcodebuild \
		-scheme $(APP) \
		-configuration Release \
		-derivedDataPath $(BUILD_PATH)/DerivedData \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		ONLY_ACTIVE_ARCH=YES \
		build
	codesign --force --deep --sign - \
		"$(BUILD_PATH)/DerivedData/Build/Products/Release/$(APP).app"
	@if [ -d "/Applications/$(APP).app" ]; then \
		osascript -e 'tell application "$(APP)" to quit' 2>/dev/null || true; \
		sleep 1; \
		rm -rf "/Applications/$(APP).app"; \
	fi
	cp -R "$(BUILD_PATH)/DerivedData/Build/Products/Release/$(APP).app" /Applications/
	xattr -cr "/Applications/$(APP).app"
	@echo "Stats installed to /Applications. Launch from Spotlight."

# Uninstall the privileged helper daemon and clear its persistent state.
# Useful when removing Stats entirely or recovering from corrupted helper
# state (stuck profile, broken takeover, mismatched protocol version, etc.).
# Stats.app itself remains in /Applications — remove via Finder if desired.
.PHONY: uninstall-helper
uninstall-helper:
	@echo "Stopping helper..."
	-sudo launchctl bootout system/eu.exelban.Stats.SMC.Helper 2>/dev/null
	@echo "Removing helper files..."
	-sudo rm -f /Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.plist
	-sudo rm -f /Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper
	@echo "Removing persistent state..."
	-sudo rm -rf "/Library/Application Support/Stats"
	@echo "Helper uninstalled. Stats.app remains in /Applications and can be removed via Finder."

# Convenience target: launch Stats so it can prompt the user to install the
# helper via SMJobBless. There's no command-line way to install a SMJobBless
# helper without the app running — the auth prompt must be raised by the
# installer process (Stats.app).
.PHONY: install-helper
install-helper:
	open /Applications/Stats.app
	@echo "Stats will prompt to install the helper. Approve to continue."