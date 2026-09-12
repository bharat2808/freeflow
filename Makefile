APP_NAME ?= FreeFlow Dev
BUNDLE_ID ?= com.zachlatta.freeflow.dev
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CODESIGN_IDENTITY ?= FreeFlow Dev
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
empty :=
space := $(empty) $(empty)
APP_EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
APP_EXECUTABLE_TARGET := $(subst $(space),\ ,$(APP_EXECUTABLE))

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
TEST_RUNNER = $(BUILD_DIR)/FreeFlowTests
WHISPER_BRIDGE_OBJECT = $(BUILD_DIR)/WhisperBridge.o
TEST_PRODUCTION_SOURCES = \
	Sources/MarkdownNoteStore.swift \
	Sources/LocalWhisperTranscriptionService.swift \
	Sources/TranscriptionService.swift \
	Sources/AppContextService.swift \
	Sources/AppName.swift \
	Sources/ClipboardController.swift \
	Sources/LLMAPITransport.swift \
	Sources/LLMCooldownManager.swift \
	Sources/ModelConfiguration.swift \
	Sources/RecordingArtifactStore.swift \
	Sources/TranscriptionErrorPresentationCore.swift \
	Sources/TranscriptTextCore.swift \
	Sources/UpdateManager.swift \
	Sources/VoiceMacroMatcher.swift \
	Sources/ShortcutCore/DictationShortcutSessionController.swift \
	Sources/ShortcutCore/ShortcutMatcher.swift \
	Sources/ShortcutCore/ShortcutModels.swift
TEST_SOURCES = $(shell find Tests -name '*.swift' -type f | LC_ALL=C sort)
SHELL_SCRIPTS = $(shell find .github/scripts .agents/skills -name '*.sh' -type f | LC_ALL=C sort)
YAML_FILES = $(shell find .github -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)
RESOURCES = $(CONTENTS)/Resources
ARCH ?= $(shell uname -m)
MARKDOWNUI_BUILD_DIR = .build/$(ARCH)-apple-macosx/debug
MARKDOWNUI_ARCHIVE = $(BUILD_DIR)/libMarkdownUI-$(ARCH).a
ifeq ($(ARCH),universal)
MARKDOWNUI_REQUIRED_ARCHIVES = $(BUILD_DIR)/libMarkdownUI-arm64.a $(BUILD_DIR)/libMarkdownUI-x86_64.a
else
MARKDOWNUI_REQUIRED_ARCHIVES = $(MARKDOWNUI_ARCHIVE)
endif

# Pick the icon source based on which bundle we are building. Dev builds get
# a distinct hammer-on-waveform icon so a developer's dock shows at a glance
# which FreeFlow they are running when both are installed side by side.
ifeq ($(APP_NAME),FreeFlow Dev)
ICON_SOURCE = Resources/AppIcon-Dev-Source.png
ICON_ICNS = Resources/AppIcon-Dev.icns
else
ICON_SOURCE = Resources/AppIcon-Source.png
ICON_ICNS = Resources/AppIcon.icns
endif

.PHONY: all check clean run icon dmg codesign-dmg notarize test typecheck validate markdownui

all: $(APP_EXECUTABLE_TARGET)

$(APP_EXECUTABLE_TARGET): $(SOURCES) $(WHISPER_BRIDGE_OBJECT) $(MARKDOWNUI_REQUIRED_ARCHIVES) Info.plist $(ICON_ICNS)
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
ifeq ($(ARCH),universal)
		swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)-arm64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target arm64-apple-macosx13.0 \
		-I ".build/arm64-apple-macosx/debug/Modules" \
		$(SOURCES) "$(BUILD_DIR)/libMarkdownUI-arm64.a"
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)-x86_64" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target x86_64-apple-macosx13.0 \
		-I ".build/x86_64-apple-macosx/debug/Modules" \
		$(SOURCES) $(WHISPER_BRIDGE_OBJECT) "$(BUILD_DIR)/libMarkdownUI-x86_64.a"
	lipo -create -output "$(MACOS_DIR)/$(APP_NAME)" \
		"$(MACOS_DIR)/$(APP_NAME)-arm64" \
		"$(MACOS_DIR)/$(APP_NAME)-x86_64"
	@rm "$(MACOS_DIR)/$(APP_NAME)-arm64" "$(MACOS_DIR)/$(APP_NAME)-x86_64"
else
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		-I "$(MARKDOWNUI_BUILD_DIR)/Modules" \
		$(SOURCES) $(WHISPER_BRIDGE_OBJECT) "$(MARKDOWNUI_ARCHIVE)"
endif
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@cp $(ICON_ICNS) "$(RESOURCES)/AppIcon.icns"
	@plutil -replace NSMicrophoneUsageDescription -string "$(APP_NAME) needs microphone access to transcribe your speech." "$(CONTENTS)/Info.plist"
	@plutil -replace NSSpeechRecognitionUsageDescription -string "$(APP_NAME) needs speech recognition to convert your voice to text." "$(CONTENTS)/Info.plist"
	@plutil -replace NSAccessibilityUsageDescription -string "$(APP_NAME) needs accessibility access to detect the text cursor position and paste transcribed text." "$(CONTENTS)/Info.plist"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements FreeFlow.entitlements "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

check: typecheck test validate

typecheck:
	swift build --target MarkdownUIBridge --disable-sandbox
	swiftc \
		-parse-as-library \
		-typecheck \
		-warnings-as-errors \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		-I "$(MARKDOWNUI_BUILD_DIR)/Modules" \
		$(SOURCES)

markdownui: $(MARKDOWNUI_REQUIRED_ARCHIVES)

$(BUILD_DIR)/libMarkdownUI-%.a: Package.swift Sources/PackageSupport/PackageSupport.swift
	@mkdir -p "$(BUILD_DIR)"
	swift build --target MarkdownUIBridge --arch "$*" --disable-sandbox
	@libtool -static -o "$@" $$(find ".build/$*-apple-macosx/debug" -type f -name '*.o' ! -path '*/MarkdownUIBridge.build/*' | LC_ALL=C sort)

test: $(WHISPER_BRIDGE_OBJECT)
	@mkdir -p "$(BUILD_DIR)"
	swiftc \
		-parse-as-library \
		-warnings-as-errors \
		-o "$(TEST_RUNNER)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx13.0 \
		$(TEST_PRODUCTION_SOURCES) $(WHISPER_BRIDGE_OBJECT) \
		$(TEST_SOURCES)
	@$(TEST_RUNNER)

ifeq ($(ARCH),universal)
$(WHISPER_BRIDGE_OBJECT): $(BUILD_DIR)/WhisperBridge-arm64.o $(BUILD_DIR)/WhisperBridge-x86_64.o
	lipo -create -output "$@" $^

$(BUILD_DIR)/WhisperBridge-arm64.o: Sources/WhisperBridge.c
	@mkdir -p "$(BUILD_DIR)"
	clang -c "$<" -o "$@" -I/opt/homebrew/include -O2 -mmacosx-version-min=13.0 -arch arm64

$(BUILD_DIR)/WhisperBridge-x86_64.o: Sources/WhisperBridge.c
	@mkdir -p "$(BUILD_DIR)"
	clang -c "$<" -o "$@" -I/opt/homebrew/include -O2 -mmacosx-version-min=13.0 -arch x86_64
else
$(WHISPER_BRIDGE_OBJECT): Sources/WhisperBridge.c
	@mkdir -p "$(BUILD_DIR)"
	clang -c "$<" -o "$@" -I/opt/homebrew/include -O2 -mmacosx-version-min=13.0 -arch $(ARCH)
endif

validate:
	plutil -lint Info.plist FreeFlow.entitlements
	@set -e; for script in $(SHELL_SCRIPTS); do bash -n "$$script"; done
	@ruby -e 'require "yaml"; ARGV.each { |file| YAML.load_file(file) }' $(YAML_FILES)

icon: $(ICON_ICNS)

$(ICON_ICNS): $(ICON_SOURCE)
	@mkdir -p $(BUILD_DIR)/AppIcon.iconset
	@sips -z 16 16 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png > /dev/null
	@sips -z 32 32 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32.png > /dev/null
	@sips -z 64 64 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png > /dev/null
	@sips -z 128 128 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png > /dev/null
	@sips -z 256 256 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png > /dev/null
	@sips -z 512 512 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512.png > /dev/null
	@sips -z 1024 1024 $< --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png > /dev/null
	@iconutil -c icns -o $@ $(BUILD_DIR)/AppIcon.iconset
	@rm -rf $(BUILD_DIR)/AppIcon.iconset
	@echo "Generated $@"

dmg: all
	@rm -f "$(BUILD_DIR)/$(APP_NAME).dmg"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@mkdir -p $(BUILD_DIR)/dmg-staging
	@cp -R "$(APP_BUNDLE)" $(BUILD_DIR)/dmg-staging/
	@osascript -e 'tell application "Finder" to make alias file to POSIX file "/Applications" at POSIX file "'"$$(cd $(BUILD_DIR)/dmg-staging && pwd)"'"'
	@ALIAS=$$(find $(BUILD_DIR)/dmg-staging -maxdepth 1 -not -name '*.app' -not -name '.DS_Store' -type f | head -1) && mv "$$ALIAS" "$(BUILD_DIR)/dmg-staging/Applications"
	@fileicon set "$(BUILD_DIR)/dmg-staging/Applications" /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns
	@echo "Creating DMG..."
	@create-dmg \
		--volname "$(APP_NAME)" \
		--volicon "$(ICON_ICNS)" \
		--background "Resources/dmg-background.tiff" \
		--window-pos 200 120 \
		--window-size 660 400 \
		--icon-size 128 \
		--icon "$(APP_NAME).app" 180 170 \
		--hide-extension "$(APP_NAME).app" \
		--icon "Applications" 480 170 \
		--no-internet-enable \
		"$(BUILD_DIR)/$(APP_NAME).dmg" \
		"$(BUILD_DIR)/dmg-staging"
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "Created $(BUILD_DIR)/$(APP_NAME).dmg"

codesign-dmg: dmg
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(BUILD_DIR)/$(APP_NAME).dmg"

notarize:
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME).dmg" \
		--keychain-profile "$(NOTARIZE_PROFILE)" --wait
	xcrun stapler staple "$(BUILD_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR)

run: all
	open "$(APP_BUNDLE)"
