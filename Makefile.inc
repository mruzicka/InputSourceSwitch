# quote the argument so as to be safe to pass as a shell command line argument
shellquote="$(subst ",\",$(subst $$,\$$,$(subst `,\`,$(subst \,\\,$(1)))))"

# quote the argument so as to be a legal C string literal
cquote="$(subst ",\",$(subst \,\\,$(1)))"

# escape spaces in the argument so as to be treated by make as a single word
makeescape=$(shell perl -e '($$_=shift(@ARGV)) =~ s/(\\*)([ \t])/\1\1\\\2/g; print' $(call shellquote,$(1)))


QUOTED.@=$(call shellquote,$@)
QUOTED.<=$(call shellquote,$<)
QUOTED.+=$(foreach p,$+,$(call shellquote,$p))
QUOTED.^=$(foreach p,$^,$(call shellquote,$p))

OUTPUT_OPTION=-o $(QUOTED.@)

%.o: %.m
	$(COMPILE.m) $(OUTPUT_OPTION) $(QUOTED.<)
