JAVA_HOME ?= $(CURDIR)/.tools/amazon-corretto-21.jdk/Contents/Home
export JAVA_HOME
export PATH := $(JAVA_HOME)/bin:$(PATH)
GO2RTC_VERSION := 1.9.15
GRADLE := .tools/gradle-8.12.1/bin/gradle
APP := build/compose/binaries/main/app/CameraWallKotlin.app

.PHONY: setup test run demo existing app

setup: .tools/go2rtc $(GRADLE) $(JAVA_HOME)/bin/java

$(JAVA_HOME)/bin/java:
	mkdir -p .tools
	curl --fail --location --show-error https://corretto.aws/downloads/latest/amazon-corretto-21-aarch64-macos-jdk.tar.gz --output .tools/corretto21.tar.gz
	tar -xzf .tools/corretto21.tar.gz -C .tools

$(GRADLE):
	mkdir -p .tools
	curl --fail --location --show-error https://services.gradle.org/distributions/gradle-8.12.1-bin.zip --output .tools/gradle.zip
	unzip -q -o .tools/gradle.zip -d .tools

.tools/go2rtc:
	mkdir -p .tools
	curl --fail --location --show-error "https://github.com/AlexxIT/go2rtc/releases/download/v$(GO2RTC_VERSION)/go2rtc_mac_arm64.zip" --output .tools/go2rtc.zip
	unzip -o .tools/go2rtc.zip -d .tools
	chmod +x .tools/go2rtc

test: setup
	./$(GRADLE) test --console=plain

run: setup
	./$(GRADLE) run --console=plain

demo: setup
	./$(GRADLE) run --console=plain --args=--demo

existing: setup
	./$(GRADLE) run --console=plain --args=--existing-relay

app: setup
	./$(GRADLE) createDistributable --console=plain
	test -x "$(APP)/Contents/app/resources/go2rtc"
	codesign --force --deep --sign - "$(APP)"