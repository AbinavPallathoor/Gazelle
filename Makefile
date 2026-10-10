# Xcode is used via DEVELOPER_DIR, so `xcode-select` can stay on the Command Line Tools.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

DERIVED := .build/xcode
APP := $(DERIVED)/Build/Products/Debug/Gazelle.app
XCODEBUILD := xcodebuild -project Gazelle.xcodeproj -scheme Gazelle -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet
SPIKE := .build/release/gazespike
M0_DIR := recordings/m0

.PHONY: project build test run signing spike m0-record m0-analyze

project:
	xcodegen generate --quiet

build: project
	$(XCODEBUILD) build

test: project
	swift test
	$(XCODEBUILD) test

run: build
	-pkill -x Gazelle
	open $(APP)

signing:
	scripts/configure-signing.sh

spike:
	swift build -c release --product gazespike

# M0: 60 s still + 60 s moving for each backend. Needs you in front of the camera.
m0-record: spike
	$(SPIKE) record --backend vision    --label still  --seconds 60 --countdown 5 --out $(M0_DIR)
	$(SPIKE) record --backend vision    --label moving --seconds 60 --countdown 5 --out $(M0_DIR)
	$(SPIKE) record --backend mediapipe --label still  --seconds 60 --countdown 5 --out $(M0_DIR)
	$(SPIKE) record --backend mediapipe --label moving --seconds 60 --countdown 5 --out $(M0_DIR)

m0-analyze: spike
	$(SPIKE) analyze $(M0_DIR)/*.jsonl
