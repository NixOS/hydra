DOCBOOK_FILES = installation.xml introduction.xml manual.xml

EXTRA_DIST = $(DOCBOOK_FILES) manual.pdf

dblatex_opts = \
 -V \
 -P doc.collab.show=0 \
 -P latex.output.revhistory=0

manual.pdf : $(DOCBOOK_FILES)
	if test "$(dblatex)" != ""; then \
	        $(dblatex) $(dblatex_opts) manual.xml; \
	else \
	        echo "Please install dblatex and rerun configure."; \
	        exit 1; \
	fi

install-data-local:
	$(INSTALL) -d $(DESTDIR)$(datadir)/doc/hydra/manual
	$(INSTALL_DATA) manual.pdf $(DESTDIR)$(datadir)/doc/hydra/manual



