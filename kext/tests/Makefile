CXX ?= clang++
# -mno-sse / -ffreestanding style checks are done by the kext build itself;
# here we build with sanitizers to catch out-of-bounds reads and UB.
CXXFLAGS ?= -std=c++17 -O1 -g -Wall -Wextra -Werror -Wno-unused-function \
            -fsanitize=address,undefined -fno-sanitize-recover=all

test: test_processor test_gesture
	./test_processor
	./test_gesture

test_gesture: test_gesture.cpp ../TouchGesture.hpp
	$(CXX) $(CXXFLAGS) -o $@ test_gesture.cpp

test_processor: test_processor.cpp ../IPTSKernelProcessor.hpp
	$(CXX) $(CXXFLAGS) -o $@ test_processor.cpp

# Proves the header uses no floating point and no libc/STL: compile it alone
# as freestanding code with SSE disabled (as kernel code would be).
kernel-check:
	echo '#include "../IPTSKernelProcessor.hpp"' > kcheck.cpp
	echo '#include "../TouchGesture.hpp"' >> kcheck.cpp
	echo 'unsigned g(stm::GestureEvent *o){ static stm::TouchGesture t; return t.update(1, true, 5, 5, o) + t.cancel(o); }' >> kcheck.cpp
	echo 'stm::HeatmapProcessor *p; stm::TouchFrame f; struct S: stm::FrameParser::Sink { void onTouch(const stm::TouchFrame&) override {} void onStylus(const stm::StylusFrame&) override {} };' >> kcheck.cpp
	echo 'bool run(const unsigned char*b,unsigned n){ S s; stm::FrameParser fp(*p); return fp.parse(b,n,s) && p->process(b,n,4,4,0,255,false,f); }' >> kcheck.cpp
	$(CXX) -std=c++17 -ffreestanding -fno-exceptions -fno-rtti -mno-sse -mno-sse2 -mno-mmx -mno-80387 -mno-red-zone -nostdinc++ -O2 -Wall -Werror -c kcheck.cpp -o kcheck.o
	rm -f kcheck.cpp kcheck.o
	@echo "kernel-check: OK (no FP, no libc/STL, freestanding)"

clean:
	rm -f test_processor test_gesture kcheck.cpp kcheck.o

.PHONY: test kernel-check clean
