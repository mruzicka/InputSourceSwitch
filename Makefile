override MAKEFILE:=$(lastword $(MAKEFILE_LIST))

#### User Configurable Variables ###############################################

APPNAME=Input Source Switch
SWITCHERBIN=$(SWITCHER_SRCNAME)
MONITORBIN=$(MONITOR_SRCNAME)
DISPLAYNAME=$(APPNAME)
BUNDLEID=net.mruza.InputSourceSwitch

TARGETDIR=$(DEFAULT_TARGETDIR)
SESSIONTYPE=Aqua

#### End Of User Configurable Variables ########################################

# note the -emit-llvm flag allows for elimination of unused code (functions) during linking
CFLAGS+=-O3 -fobjc-arc -emit-llvm -DISS_MONITOR_EXECUTABLE=$(call shellquote,$(call cquote,$(MONITORBIN))) -DISS_SERVER_PORT_NAME=$(call shellquote,$(call cquote,$(BUNDLEID).port))
SWITCHER_LDLIBS=-framework AppKit -framework Carbon
MONITOR_LDLIBS=-framework Foundation -framework IOKit

override UTILS_SRCNAME=ISSUtils
override SWITCHER_SRCNAME=InputSourceSwitch
override MONITOR_SRCNAME=KeyboardMonitor
override DEFAULT_TARGETDIR=installroot
override VARSFILE=.$(MAKEFILE).vars

BUNDLEDIR=$(if $(patsubst /%,%,$(TARGETDIR)),$(TARGETDIR))/Applications/$(APPNAME).app
BUNDLECONTENTSDIR=$(BUNDLEDIR)/Contents
BUNDLEEXEDIR=$(BUNDLECONTENTSDIR)/MacOS
AGENTDIR=$(if $(patsubst /%,%,$(TARGETDIR)),$(TARGETDIR))/Library/LaunchAgents

INFOFILE=Info.plist
INFOFILETEMPLATE=$(INFOFILE).template
AGENTFILE=$(BUNDLEID).plist
AGENTFILETEMPLATE=LaunchAgent.plist.template

UTILS_OBJFILE=$(UTILS_SRCNAME).o

SWITCHER_OBJFILE=$(SWITCHER_SRCNAME).o
SWITCHER_EXEFILE=$(SWITCHERBIN)

MONITOR_OBJFILE=$(MONITOR_SRCNAME).o
MONITOR_EXEFILE=$(MONITORBIN)

include Makefile.inc

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

VARS_CHANGED:=$(shell \
	python -c 'import $(BUILD_UTILS); $(BUILD_UTILS).checkAndSaveMakeVariables()' \
	$(call shellquote,$(VARSFILE)) $(call shellquote,$(MAKEFILE)) \
	$(foreach v,$(.VARIABLES),$(call shellquote,$v) $(call shellquote,$($v))) \
)


.PHONY: all load unload install uninstall clean cleanall $(if $(VARS_CHANGED),$(MAKEFILE))


all: $(M_SWITCHER_EXEFILE) $(M_MONITOR_EXEFILE) |

$(M_UTILS_OBJFILE): $(call makeescape,$(UTILS_SRCNAME).m) $(call makeescape,$(UTILS_SRCNAME).h) $(MAKEFILE)

$(M_SWITCHER_OBJFILE): $(call makeescape,$(SWITCHER_SRCNAME).m) $(call makeescape,$(SWITCHER_SRCNAME).h) $(call makeescape,$(UTILS_SRCNAME).h) $(MAKEFILE)

$(M_MONITOR_OBJFILE): $(call makeescape,$(MONITOR_SRCNAME).m) $(call makeescape,$(SWITCHER_SRCNAME).h) $(call makeescape,$(UTILS_SRCNAME).h) $(MAKEFILE)

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

$(M_BUNDLECONTENTSDIR)/$(M_INFOFILE): $(M_INFOFILETEMPLATE) $(MAKEFILE) | $(M_BUNDLECONTENTSDIR)
	install -M -m 644 /dev/null $(QUOTED.@)
	python -c 'import $(BUILD_UTILS); $(BUILD_UTILS).processPList()' $(QUOTED.<) \
	CFBundleDisplayName $(call shellquote,$(call cquote,$(DISPLAYNAME))) \
	CFBundleExecutable  $(call shellquote,$(call cquote,$(SWITCHER_EXEFILE))) \
	CFBundleIdentifier  $(call shellquote,$(call cquote,$(BUNDLEID))) \
	> $(QUOTED.@)

$(M_BUNDLEEXEDIR)/$(M_SWITCHER_EXEFILE): $(M_SWITCHER_EXEFILE) | $(M_BUNDLEEXEDIR)
	install -m 755 $(QUOTED.<) $(QUOTED.@)

$(M_BUNDLEEXEDIR)/$(M_MONITOR_EXEFILE): $(M_MONITOR_EXEFILE) | $(M_BUNDLEEXEDIR)
	install -m 755 $(QUOTED.<) $(QUOTED.@)

$(M_AGENTDIR)/$(M_AGENTFILE): $(M_AGENTFILETEMPLATE) $(MAKEFILE) | $(M_AGENTDIR)
	install -M -m 644 /dev/null $(QUOTED.@)
	python -c 'import $(BUILD_UTILS); $(BUILD_UTILS).processPList()' $(QUOTED.<) \
	Label                  $(call shellquote,$(call cquote,$(APPNAME))) \
	ProgramArguments       $(call shellquote,getProgramArguments($(call cquote,$(BUNDLEEXEDIR)/$(SWITCHER_EXEFILE)))) \
	LimitLoadToSessionType $(call shellquote,getSessionTypes($(call cquote,$(SESSIONTYPE)))) \
	> $(QUOTED.@)

install: $(M_BUNDLECONTENTSDIR)/$(M_INFOFILE) $(M_BUNDLEEXEDIR)/$(M_SWITCHER_EXEFILE) $(M_BUNDLEEXEDIR)/$(M_MONITOR_EXEFILE) $(M_AGENTDIR)/$(M_AGENTFILE)

load: install
	launchctl load $(call shellquote,$(AGENTDIR)/$(AGENTFILE))

unload:
	[ -f $(call shellquote,$(AGENTDIR)/$(AGENTFILE)) ] && launchctl unload $(call shellquote,$(AGENTDIR)/$(AGENTFILE)) || :

uninstall: unload
	-rm -rf $(call shellquote,$(BUNDLEDIR))
	-rm -f  $(call shellquote,$(AGENTDIR)/$(AGENTFILE))

clean:
	-rm -f  $(call shellquote,$(UTILS_OBJFILE)) $(call shellquote,$(SWITCHER_OBJFILE)) $(call shellquote,$(MONITOR_OBJFILE))

cleanall: clean
	-rm -f  $(call shellquote,$(SWITCHER_EXEFILE)) $(call shellquote,$(MONITOR_EXEFILE))
	-rm -rf $(call shellquote,$(DEFAULT_TARGETDIR))
	-rm -f  $(call shellquote,$(BUILD_UTILS).pyc)
	-rm -f  $(call shellquote,$(VARSFILE))
