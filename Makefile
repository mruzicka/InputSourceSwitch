#### User Configurable Variables ###############################################

APPNAME=$(SRCNAME)
#APPNAME=$(DISPLAYNAME)
DISPLAYNAME=Input Source Switch
BUNDLEID=net.mruza.InputSourceSwitch

TARGETDIR=$(DEFAULT_TARGETDIR)

#### End Of User Configurable Variables ########################################

CFLAGS+=-O3 -fobjc-arc
LDLIBS=-framework AppKit -framework IOKit -framework Carbon

override SRCNAME=InputSourceSwitch
override DEFAULT_TARGETDIR=installroot

BUNDLEDIR=$(TARGETDIR)/Applications/$(APPNAME).app
BUNDLECONTENTSDIR=$(BUNDLEDIR)/Contents
BUNDLEEXEDIR=$(BUNDLECONTENTSDIR)/MacOS
AGENTDIR=$(TARGETDIR)/Library/LaunchAgents

OBJFILE=$(SRCNAME).o
EXEFILE=$(APPNAME)
INFOFILE=Info.plist
INFOFILETEMPLATE=$(INFOFILE).template
AGENTFILE=$(APPNAME).plist
AGENTFILETEMPLATE=$(SRCNAME).plist.template


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

M_OBJFILE:=$(call makeescape,$(OBJFILE))
M_EXEFILE:=$(call makeescape,$(EXEFILE))
M_INFOFILE:=$(call makeescape,$(INFOFILE))
M_INFOFILETEMPLATE:=$(call makeescape,$(INFOFILETEMPLATE))
M_AGENTFILE:=$(call makeescape,$(AGENTFILE))
M_AGENTFILETEMPLATE:=$(call makeescape,$(AGENTFILETEMPLATE))



all: $(M_EXEFILE)

$(M_OBJFILE): $(call makeescape,$(SRCNAME).m) $(call makeescape,$(SRCNAME).h) Makefile

$(M_EXEFILE): $(M_OBJFILE)
	$(LINK.o) $(QUOTED.<) $(LDLIBS) $(OUTPUT_OPTION)

$(M_TARGETDIR):
	T=$(QUOTED.@); \
	install -d "$$T"

$(M_BUNDLEDIR) $(M_AGENTDIR): $(M_TARGETDIR)
	T=$(QUOTED.@); \
	[ -d "$$T" ] && touch "$$T" || install -d -m 755 "$$T"

$(M_BUNDLECONTENTSDIR): $(M_BUNDLEDIR)
	T=$(QUOTED.@); \
	[ -d "$$T" ] && touch "$$T" || install -d -m 755 "$$T"

$(M_BUNDLEEXEDIR): $(M_BUNDLECONTENTSDIR)
	T=$(QUOTED.@); \
	[ -d "$$T" ] && touch "$$T" || install -d -m 755 "$$T"

$(M_BUNDLECONTENTSDIR)/$(M_INFOFILE): $(M_INFOFILETEMPLATE) $(M_BUNDLECONTENTSDIR) Makefile
	T=$(QUOTED.@); S=$(QUOTED.<); \
	install -m 644 "$$S" "$$T"
	TA=$(call shellquote,$(call absolutepath,$@)); \
	defaults write "$$TA" CFBundleDisplayName -string $(call shellquote,$(DISPLAYNAME)); \
	defaults write "$$TA" CFBundleExecutable -string $(call shellquote,$(EXEFILE)); \
	defaults write "$$TA" CFBundleIdentifier -string $(call shellquote,$(BUNDLEID)); \
	plutil -convert xml1 "$$TA"

$(M_BUNDLEEXEDIR)/$(M_EXEFILE): $(M_EXEFILE) $(M_BUNDLEEXEDIR)
	T=$(QUOTED.@); S=$(QUOTED.<); \
	install -m 755 -s "$$S" "$$T"

$(M_AGENTDIR)/$(M_AGENTFILE): $(M_AGENTFILETEMPLATE) $(M_AGENTDIR) Makefile
	T=$(QUOTED.@); S=$(QUOTED.<); \
	install -m 644 "$$S" "$$T"
	TA=$(call shellquote,$(call absolutepath,$@)); \
	defaults write "$$TA" Label -string $(call shellquote,$(APPNAME)); \
	defaults write "$$TA" ProgramArguments -array $(call shellquote,$(call replacehome,$(BUNDLEEXEDIR)/$(EXEFILE))); \
	plutil -convert xml1 "$$TA"

install: $(M_BUNDLECONTENTSDIR)/$(M_INFOFILE) $(M_BUNDLEEXEDIR)/$(M_EXEFILE) $(M_AGENTDIR)/$(M_AGENTFILE)

load: install
	AF=$(call shellquote,$(AGENTDIR)/$(AGENTFILE)); \
	launchctl load "$$AF"

unload:
	AF=$(call shellquote,$(AGENTDIR)/$(AGENTFILE)); \
	[ -f "$$AF" ] && launchctl unload "$$AF" || :

uninstall: unload
	-rm -rf $(call shellquote,$(BUNDLEDIR))
	-rm -f $(call shellquote,$(AGENTDIR)/$(AGENTFILE))

clean:
	-rm -f $(call shellquote,$(OBJFILE))

cleanall: clean
	-rm -f $(call shellquote,$(EXEFILE))
	-rm -rf $(call shellquote,$(DEFAULT_TARGETDIR))
