ALL=InputSourceSwitch

CFLAGS+=-O3 -fobjc-arc
LDLIBS=-framework Foundation -framework IOKit -framework Carbon

all: $(ALL)

clean:
	-rm -f *.o

cleanall: clean
	-rm -f $(ALL)

InputSourceSwitch.o: InputSourceSwitch.m InputSourceSwitch.h
