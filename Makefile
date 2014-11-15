# TODO Makefile to be the source of truth

NAME=InputSourceSwitch

DEFAULT_TARGETDIR=installroot
TARGETDIR=$(DEFAULT_TARGETDIR)
BUNDLEDIR=$(TARGETDIR)/Applications/$(NAME).app
BUNDLECONTENTSDIR=$(BUNDLEDIR)/Contents
BUNDLEBINDIR=$(BUNDLECONTENTSDIR)/MacOS
AGENTDIR=$(TARGETDIR)/Library/LaunchAgents
EXEFILE=$(NAME)
INFOFILE=Info.plist
AGENTFILE=$(NAME).plist

CFLAGS+=-O3 -fobjc-arc
LDLIBS=-framework AppKit -framework IOKit -framework Carbon

all: $(EXEFILE)

$(NAME).o: $(NAME).m $(NAME).h

$(TARGETDIR):
	install -d $@

$(BUNDLEDIR) $(AGENTDIR): $(TARGETDIR)
	[ -d $@ ] && touch $@ || install -d -m 755 $@

$(BUNDLECONTENTSDIR): $(BUNDLEDIR)
	[ -d $@ ] && touch $@ || install -d -m 755 $@

$(BUNDLEBINDIR): $(BUNDLECONTENTSDIR)
	[ -d $@ ] && touch $@ || install -d -m 755 $@

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
	-rm -f $(NAME).o

cleanall: clean
	-rm -f $(EXEFILE)
	-rm -rf $(DEFAULT_TARGETDIR)
