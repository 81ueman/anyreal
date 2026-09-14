CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -g -Wall -Wextra
BUILD := ../build

.PHONY: all clean
all: $(BUILD)/anyreal-run $(BUILD)/m2-relay $(BUILD)/libprobe.so

$(BUILD)/anyreal-run: launcher/main.cpp broker/broker.cpp broker/broker.h \
		common/sc.h common/real_proto.h common/m2.h
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) launcher/main.cpp broker/broker.cpp -o $@ -lpthread

$(BUILD)/m2-relay: relay/m2_relay.cpp common/m2.h
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) relay/m2_relay.cpp -o $@

$(BUILD)/libprobe.so: probe/probe.c
	@mkdir -p $(BUILD)
	$(CC) -shared -fPIC -O2 -o $@ probe/probe.c -ldl

clean:
	rm -f $(BUILD)/anyreal-run $(BUILD)/m2-relay $(BUILD)/libprobe.so
