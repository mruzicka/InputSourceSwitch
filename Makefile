NAME=InputSourceSwitch

DEFAULT_TARGETDIR=installroot
TARGETDIR=$(DEFAULT_TARGETDIR)
BUNDLEDIR=$(TARGETDIR)/Library/$(NAME)
BUNDLEBINDIR=$(BUNDLEDIR)/Contents/MacOS
AGENTDIR=$(TARGETDIR)/Library/LaunchAgents
AGENTFILE=$(NAME).plist

CFLAGS+=-O3 -fobjc-arc
LDLIBS=-framework Foundation -framework IOKit -framework Carbon

all: $(NAME)

$(NAME).o: $(NAME).m $(NAME).h

$(TARGETDIR):
	install -d $@

$(BUNDLEDIR) $(AGENTDIR): $(TARGETDIR)
	install -d -m 755 $@

$(BUNDLEBINDIR): $(BUNDLEDIR)
	install -d -m 755 $@

$(BUNDLEBINDIR)/$(NAME): $(NAME) $(BUNDLEBINDIR)
	install -m 755 $(NAME) $(BUNDLEBINDIR)

$(AGENTDIR)/$(AGENTFILE): $(AGENTFILE) $(AGENTDIR)
	install -m 644 $(AGENTFILE) $(AGENTDIR)

install: $(BUNDLEBINDIR)/$(NAME) $(AGENTDIR)/$(AGENTFILE)

uninstall:
	-rm -rf $(BUNDLEDIR)
	-rm -f $(AGENTDIR)/$(AGENTFILE)

clean:
	-rm -f *.o

cleanall: clean
	-rm -f $(NAME)
	-rm -rf $(DEFAULT_TARGETDIR)
