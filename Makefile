#### User Configurable Variables ###############################################

APPNAME=Input Source Switch
SWITCHERBIN=$(SWITCHER_SRCNAME)
MONITORBIN=$(MONITOR_SRCNAME)
DISPLAYNAME=$(APPNAME)
BUNDLEID=net.mruza.InputSourceSwitch

TARGETDIR=$(DEFAULT_TARGETDIR)

#### End Of User Configurable Variables ########################################

# note the -emit-llvm flag allows for elimination of unused code (functions) during linking
CFLAGS+=-O3 -fobjc-arc -emit-llvm -DISS_MONITOR_EXECUTABLE=$(call shellquote,$(call cquote,$(MONITORBIN))) -DISS_SERVER_PORT_NAME=$(call shellquote,$(call cquote,$(BUNDLEID).port))
SWITCHER_LDLIBS=-framework AppKit -framework Carbon -lbsm
MONITOR_LDLIBS=-framework Foundation -framework IOKit

override UTILS_SRCNAME=ISSUtils
override SWITCHER_SRCNAME=InputSourceSwitch
override MONITOR_SRCNAME=KeyboardMonitor
override DEFAULT_TARGETDIR=installroot

BUNDLEDIR=$(TARGETDIR)/Applications/$(APPNAME).app
BUNDLECONTENTSDIR=$(BUNDLEDIR)/Contents
BUNDLEEXEDIR=$(BUNDLECONTENTSDIR)/MacOS
AGENTDIR=$(TARGETDIR)/Library/LaunchAgents

INFOFILE=Info.plist
INFOFILETEMPLATE=$(INFOFILE).template
AGENTFILE=$(APPNAME).plist
AGENTFILETEMPLATE=$(SWITCHER_SRCNAME).plist.template

UTILS_OBJFILE=$(UTILS_SRCNAME).o

SWITCHER_OBJFILE=$(SWITCHER_SRCNAME).o
SWITCHER_EXEFILE=$(SWITCHERBIN)

MONITOR_OBJFILE=$(MONITOR_SRCNAME).o
MONITOR_EXEFILE=$(MONITORBIN)

include Makefile.inc

# if the argument is not an absolute path then prepend the current working directory to it
absolutepath=$(shell perl -e 'use File::Spec::Functions qw(:ALL); $$_=rel2abs(shift(@ARGV)); print' $(call shellquote,$(1)))

# if the argument starts with the home directory path then replace that portion of the argument with ~
replacehome=$(shell perl -e 'use File::Spec::Functions qw(:ALL); $$_=canonpath(shift(@ARGV)); $$h=canonpath($$ENV{HOME}); file_name_is_absolute($$_) && ($$l_=length($$_)) >= ($$lh=length($$h)) && substr($$_,0,$$lh) eq $$h && ($$l_ == $$lh || substr($$_,$$lh,1) eq q(/)) and $$_=q(~).substr($$_,$$lh); print' $(call shellquote,$(1)))

M_TARGETDIR:=$(call makeescape,$(TARGETDIR))
M_BUNDLEDIR:=$(call makeescape,$(BUNDLEDIR))
M_BUNDLECONTENTSDIR:=$(call makeescape,$(BUNDLECONTENTSDIR))
M_BUNDLEEXEDIR:=$(call makeescape,$(BUNDLEEXEDIR))
M_AGENTDIR:=$(call makeescape,$(AGENTDIR))

M_INFOFILE:=$(call makeescape,$(INFOFILE))
M_INFOFILETEMPLATE:=$(call makeescape,$(INFOFILETEMPLATE))
M_AGENTFILE:=$(call makeescape,$(AGENTFILE))
M_AGENTFILETEMPLATE:=$(call makeescape,$(AGENTFILETEMPLATE))

M_UTILS_OBJFILE:=$(call makeescape,$(UTILS_OBJFILE))

M_SWITCHER_OBJFILE:=$(call makeescape,$(SWITCHER_OBJFILE))
M_SWITCHER_EXEFILE:=$(call makeescape,$(SWITCHER_EXEFILE))

M_MONITOR_OBJFILE:=$(call makeescape,$(MONITOR_OBJFILE))
M_MONITOR_EXEFILE:=$(call makeescape,$(MONITOR_EXEFILE))


all: $(M_SWITCHER_EXEFILE) $(M_MONITOR_EXEFILE)

$(M_UTILS_OBJFILE): $(call makeescape,$(UTILS_SRCNAME).m) $(call makeescape,$(UTILS_SRCNAME).h) Makefile

$(M_SWITCHER_OBJFILE): $(call makeescape,$(SWITCHER_SRCNAME).m) $(call makeescape,$(SWITCHER_SRCNAME).h) $(call makeescape,$(UTILS_SRCNAME).h) Makefile

$(M_MONITOR_OBJFILE): $(call makeescape,$(MONITOR_SRCNAME).m) $(call makeescape,$(SWITCHER_SRCNAME).h) $(call makeescape,$(UTILS_SRCNAME).h) Makefile

$(M_SWITCHER_EXEFILE): $(M_SWITCHER_OBJFILE) $(M_UTILS_OBJFILE)
	$(LINK.o) $(QUOTED.^) $(SWITCHER_LDLIBS) $(OUTPUT_OPTION)

$(M_MONITOR_EXEFILE): $(M_MONITOR_OBJFILE) $(M_UTILS_OBJFILE)
	$(LINK.o) $(QUOTED.^) $(MONITOR_LDLIBS) $(OUTPUT_OPTION)

$(M_TARGETDIR):
	install -d $(QUOTED.@)

$(M_BUNDLEDIR): | $(M_TARGETDIR)
	install -d -m 755 $(QUOTED.@)

$(M_AGENTDIR): | $(M_TARGETDIR)
	install -d $(QUOTED.@)

$(M_BUNDLECONTENTSDIR): | $(M_BUNDLEDIR)
	install -d -m 755 $(QUOTED.@)

$(M_BUNDLEEXEDIR): | $(M_BUNDLECONTENTSDIR)
	install -d -m 755 $(QUOTED.@)

$(M_BUNDLECONTENTSDIR)/$(M_INFOFILE): $(M_INFOFILETEMPLATE) Makefile | $(M_BUNDLECONTENTSDIR)
	install -m 644 $(QUOTED.<) $(QUOTED.@)
	PROPS=$(call shellquote,$(call absolutepath,$@)); \
	defaults write "$$PROPS" CFBundleDisplayName -string $(call shellquote,$(DISPLAYNAME)); \
	defaults write "$$PROPS" CFBundleExecutable -string $(call shellquote,$(SWITCHER_EXEFILE)); \
	defaults write "$$PROPS" CFBundleIdentifier -string $(call shellquote,$(BUNDLEID)); \
	plutil -convert xml1 "$$PROPS"

$(M_BUNDLEEXEDIR)/%: %
	install -m 755 $(QUOTED.<) $(QUOTED.@)

$(M_BUNDLEEXEDIR)/$(M_SWITCHER_EXEFILE): $(M_SWITCHER_EXEFILE) | $(M_BUNDLEEXEDIR)

$(M_BUNDLEEXEDIR)/$(M_MONITOR_EXEFILE): $(M_MONITOR_EXEFILE) | $(M_BUNDLEEXEDIR)

$(M_AGENTDIR)/$(M_AGENTFILE): $(M_AGENTFILETEMPLATE) Makefile | $(M_AGENTDIR)
	install -m 644 $(QUOTED.<) $(QUOTED.@)
	PROPS=$(call shellquote,$(call absolutepath,$@)); \
	defaults write "$$PROPS" Label -string $(call shellquote,$(APPNAME)); \
	defaults write "$$PROPS" ProgramArguments -array $(call shellquote,$(call replacehome,$(BUNDLEEXEDIR)/$(SWITCHER_EXEFILE))); \
	plutil -convert xml1 "$$PROPS"

install: $(M_BUNDLECONTENTSDIR)/$(M_INFOFILE) $(M_BUNDLEEXEDIR)/$(M_SWITCHER_EXEFILE) $(M_BUNDLEEXEDIR)/$(M_MONITOR_EXEFILE) $(M_AGENTDIR)/$(M_AGENTFILE)

load: install
	launchctl load $(call shellquote,$(AGENTDIR)/$(AGENTFILE))

unload:
	[ -f $(call shellquote,$(AGENTDIR)/$(AGENTFILE)) ] && launchctl unload $(call shellquote,$(AGENTDIR)/$(AGENTFILE)) || :

uninstall: unload
	-rm -rf $(call shellquote,$(BUNDLEDIR))
	-rm -f $(call shellquote,$(AGENTDIR)/$(AGENTFILE))

clean:
	-rm -f $(call shellquote,$(UTILS_OBJFILE))
	-rm -f $(call shellquote,$(SWITCHER_OBJFILE))
	-rm -f $(call shellquote,$(MONITOR_OBJFILE))

cleanall: clean
	-rm -f $(call shellquote,$(SWITCHER_EXEFILE))
	-rm -f $(call shellquote,$(MONITOR_EXEFILE))
	-rm -rf $(call shellquote,$(DEFAULT_TARGETDIR))
