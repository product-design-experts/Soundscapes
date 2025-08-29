# Assuming you've built and installed libsoup-3.0 locally as previously described
CC = gcc
LOCAL_PREFIX := $(HOME)/local
PKG_CONFIG_PATH := $(LOCAL_PREFIX)/lib/pkgconfig:$(PKG_CONFIG_PATH)

CFLAGS += -I$(LOCAL_PREFIX)/include
LDFLAGS += -L$(LOCAL_PREFIX)/lib -Wl,-rpath,$(LOCAL_PREFIX)/lib

STUFF = $(shell PKG_CONFIG_PATH=$(PKG_CONFIG_PATH) pkg-config --cflags \
        "gstreamer-webrtc-1.0 >= 1.16" \
        "gstreamer-sdp-1.0 >= 1.16" \
        gstreamer-video-1.0 \
        libsoup-3.0 \
        json-glib-1.0) -D_GNU_SOURCE

STUFF_LIBS = $(shell PKG_CONFIG_PATH=$(PKG_CONFIG_PATH) pkg-config --libs \
             "gstreamer-webrtc-1.0 >= 1.16" \
             "gstreamer-sdp-1.0 >= 1.16" \
             gstreamer-video-1.0 \
             libsoup-3.0 \
             json-glib-1.0)

OPTS = -Wall -Wstrict-prototypes -Wmissing-prototypes \
       -Wmissing-declarations -Wunused
CFLAGS += $(shell pkg-config --cflags gstreamer-1.0)
LDFLAGS += $(shell pkg-config --libs gstreamer-1.0)

GDB = -g -ggdb
OBJS = src/whip-client.o

all: whip-client

%.o: %.c
	$(CC) $(ASAN) $(CFLAGS) $(STUFF) -fPIC $(GDB) -c $< -o $@ $(OPTS)

whip-client: $(OBJS)
	$(CC) $(GDB) -o whip-client $(OBJS) $(LDFLAGS) $(ASAN_LIBS) $(STUFF_LIBS)
clean:
	rm -f whip-client src/*.o
