APP = HomeStream.app
BUNDLE = .build/$(APP)

build:
	swift build -c release
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp -f .build/release/Homestream $(BUNDLE)/Contents/MacOS/Homestream
	cp -f Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)

install: build
	cp -rf $(BUNDLE) /Applications/$(APP)

run: build
	open $(BUNDLE)

clean:
	swift package clean
	rm -rf .build/$(APP)

.PHONY: build install run clean
