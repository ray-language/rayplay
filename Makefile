# RayPlay — common tasks. `make` (or `make help`) lists them.

APP     := RayPlay
IOS     := $(APP)-ios
ANDROID := $(APP)-android

.DEFAULT_GOAL := help
.PHONY: help run dev dev-device test test-native icon bundle-macos bundle-ios ios-lib ios-lib-sim ios-libs ios-sim-build bundle-android android-apk bundle-ios-dev bundle-android-dev android-dev-apk

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-16s %s\n", $$1, $$2}'

run: ## Desktop window (the page from www/, sound from std/audio)
	ray run

dev: ## Same, restarting on changes
	ray dev

# Live development on the phone (raylang 1.27.25): install the development shell once
# (bundle-ios-dev / bundle-android-dev), then scan the QR this prints; every saved change in
# src/, www/ or ray.toml reloads the program there and its print/eprint land here.
dev-device: ## Push the program to the phone's development shell on every change
	ray dev --device

# The audio output is a real-time null sink under test: no sound card, the clock still runs.
test: ## Backend tests (WAV codec, tracks, the player actor, the protocol)
	RAY_AUDIO_SINK=null ray test

test-native: ## The same tests as native binaries
	RAY_AUDIO_SINK=null ray test --native

icon: ## Render assets/icon.png
	ray run scripts/make-icon.ray

# ---- macOS ----

bundle-macos: ## Build RayPlay.app
	ray bundle

# ---- iOS ----

bundle-ios: ## (Re)generate the Xcode project in RayPlay-ios/ (device + simulator libraries)
	ray bundle --ios

ios-lib: ## Rebuild the iPhone static library after a change (Xcode project untouched)
	ray build --native --lib --release --target aarch64-apple-ios -o $(IOS)/libs/libray_app.a

ios-lib-sim: ## Rebuild the simulator static library
	ray build --native --lib --release --target aarch64-apple-ios-sim -o $(IOS)/libs-sim/libray_app.a

ios-libs: ios-lib ios-lib-sim ## Both libraries

ios-sim-build: ios-lib-sim ## Build the app for the simulator (unsigned)
	cd $(IOS) && xcodebuild -project $(APP).xcodeproj -target $(APP) -sdk iphonesimulator \
		-configuration Debug build CODE_SIGNING_ALLOWED=NO

# ---- Android ----

bundle-android: ## (Re)generate the Gradle project in RayPlay-android/ (arm64)
	ray bundle --android --android-abi arm64

android-apk: ## Build the debug APK from RayPlay-android/
	cd $(ANDROID) && gradle assembleDebug

# ---- Live development (development shell, id org.raylang.rayplay.dev) ----

bundle-ios-dev: ## Xcode project of the development shell in RayPlay-dev-ios/
	ray bundle --ios --dev

bundle-android-dev: ## Gradle project of the development shell in RayPlay-dev-android/ (arm64)
	ray bundle --android --dev --android-abi arm64

android-dev-apk: ## Build the development shell's debug APK
	cd $(APP)-dev-android && gradle assembleDebug
