# RayPlay — common tasks. `make` (or `make help`) lists them.

APP     := RayPlay
IOS     := $(APP)-ios
ANDROID := $(APP)-android

.DEFAULT_GOAL := help
.PHONY: help run dev test test-native icon bundle-macos bundle-ios ios-lib ios-lib-sim ios-libs ios-sim-build bundle-android android-apk

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-16s %s\n", $$1, $$2}'

run: ## Desktop window (the page from www/, sound from std/audio)
	ray run

dev: ## Same, restarting on changes
	ray dev

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
