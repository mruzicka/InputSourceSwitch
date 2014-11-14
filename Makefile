NAME=InputSourceSwitch

DEFAULT_TARGETDIR=installroot
TARGETDIR=$(DEFAULT_TARGETDIR)
BUNDLEDIR=$(TARGETDIR)/Library/$(NAME)
BUNDLECONTENTSDIR=$(BUNDLEDIR)/Contents
BUNDLEBINDIR=$(BUNDLECONTENTSDIR)/MacOS
AGENTDIR=$(TARGETDIR)/Library/LaunchAgents
EXEFILE=$(NAME)
INFOFILE=Info.plist
AGENTFILE=$(NAME).plist

CFLAGS+=-O3 -fobjc-arc
LDLIBS=-framework Foundation -framework IOKit -framework Carbon

all: $(NAME)

$(NAME).o: $(NAME).m $(NAME).h

$(TARGETDIR):
	install -d $@

$(BUNDLEDIR) $(AGENTDIR): $(TARGETDIR)
	install -d -m 755 $@
	touch $@

$(BUNDLECONTENTSDIR): $(BUNDLEDIR)
	install -d -m 755 $@
	touch $@

$(BUNDLEBINDIR): $(BUNDLECONTENTSDIR)
	install -d -m 755 $@
	touch $@

$(BUNDLECONTENTSDIR)/$(INFOFILE): $(INFOFILE) $(BUNDLECONTENTSDIR)
	install -m 644 $(INFOFILE) $(BUNDLECONTENTSDIR)

$(BUNDLEBINDIR)/$(EXEFILE): $(EXEFILE) $(BUNDLEBINDIR)
	install -m 755 $(EXEFILE) $(BUNDLEBINDIR)

$(AGENTDIR)/$(AGENTFILE): $(AGENTFILE) $(AGENTDIR)
	install -m 644 $(AGENTFILE) $(AGENTDIR)

install: $(BUNDLECONTENTSDIR)/$(INFOFILE) $(BUNDLEBINDIR)/$(EXEFILE) $(AGENTDIR)/$(AGENTFILE)

uninstall:
	-rm -rf $(BUNDLEDIR)
	-rm -f $(AGENTDIR)/$(AGENTFILE)

clean:
	-rm -f *.o

cleanall: clean
	-rm -f $(NAME)
	-rm -rf $(DEFAULT_TARGETDIR)
