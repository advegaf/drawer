export DEVELOPER_DIR ?= $(shell xcode-select -p)

PROJECT := Drawer.xcodeproj
SCHEME  := Drawer
DEST    := platform=macOS,arch=arm64

.PHONY: gen build test run clean shot icon

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug build

test: gen
	pkill -x Drawer || true
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug test

run: build
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/Drawer.app; \
	pkill -x Drawer || true; \
	open "$$APP"

clean:
	rm -rf build DerivedData *.xcodeproj

shot: ; ./Scripts/shot.sh $(NAME) $(ENV)

icon: ; swift Scripts/make-icon.swift Sources/Assets.xcassets/AppIcon.appiconset Design/icon/exports
