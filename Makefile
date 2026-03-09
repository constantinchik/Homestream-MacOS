APP = HomeStream.app
BUNDLE = .build/$(APP)

build:
	swift build -c release
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp -f .build/release/Homestream $(BUNDLE)/Contents/MacOS/Homestream
	cp -f Info.plist $(BUNDLE)/Contents/Info.plist
	cp -f Assets/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(BUNDLE)

install: build
	cp -rf $(BUNDLE) /Applications/$(APP)

run: build
	open $(BUNDLE)

clean:
	swift package clean
	rm -rf .build/$(APP)

reset:
	pkill -x Homestream || true
	tccutil reset ScreenCapture com.homestream.app
	tccutil reset Camera com.homestream.app

dev: install reset
	open /Applications/$(APP)

.PHONY: build install run clean reset dev
