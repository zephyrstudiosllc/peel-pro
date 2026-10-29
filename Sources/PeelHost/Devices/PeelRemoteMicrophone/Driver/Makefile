CORE_DIR := ../Core
BUILD_DIR ?= build
BUNDLE := $(BUILD_DIR)/PeelRemoteMicrophone.driver
CONTENTS := $(BUNDLE)/Contents
EXECUTABLE := $(CONTENTS)/MacOS/PeelRemoteMicrophone
PLIST := $(CONTENTS)/Info.plist

MACOSX_DEPLOYMENT_TARGET ?= 13.0
XCRUN ?= xcrun
CLANG := $(XCRUN) --sdk macosx clang

SOURCES := \
	PeelRemoteMicrophoneDriver.c \
	PeelRemoteMicrophoneIO.c \
	ProducerAuthentication.c \
	ProducerLifecycle.c \
	ProducerProtocol.c \
	$(CORE_DIR)/PeelAudioRing.c

CFLAGS := \
	-std=c11 \
	-Wall \
	-Wextra \
	-Werror \
	-fPIC \
	-fvisibility=hidden \
	-mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) \
	-I"." \
	-I"$(CORE_DIR)"

LDFLAGS := \
	-bundle \
	-mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) \
	-framework CoreAudio \
	-framework CoreFoundation \
	-framework Security

.PHONY: all clean check test

all: $(EXECUTABLE) $(PLIST)

$(EXECUTABLE): $(SOURCES) \
		PeelRemoteMicrophoneIO.h \
		PeelRemoteMicrophoneProducer.h \
		ProducerAuthentication.h \
		ProducerLifecycle.h \
		ProducerProtocol.h \
		$(CORE_DIR)/PeelAudioRing.h
	mkdir -p "$(dir $@)"
	$(CLANG) $(CFLAGS) \
		"PeelRemoteMicrophoneDriver.c" \
		"PeelRemoteMicrophoneIO.c" \
		"ProducerAuthentication.c" \
		"ProducerLifecycle.c" \
		"ProducerProtocol.c" \
		"$(CORE_DIR)/PeelAudioRing.c" \
		$(LDFLAGS) \
		-o "$@"

$(PLIST): Info.plist
	mkdir -p "$(dir $@)"
	cp "$<" "$@"

check: all
	plutil -lint "$(PLIST)"
	$(XCRUN) nm -gU "$(EXECUTABLE)" | \
		awk '$$NF == "_PeelRemoteMicrophone_Create" { found = 1 } END { exit !found }'

test:
	"./Tests/run-tests.sh"

clean:
	rm -rf "$(BUILD_DIR)"
