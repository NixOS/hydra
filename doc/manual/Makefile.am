DOCBOOK_FILES = installation.xml introduction.xml manual.xml projects.xml

EXTRA_DIST = $(DOCBOOK_FILES) manual.pdf

dblatex_opts = \
 -V \
 -P doc.collab.show=0 \
 -P latex.output.revhistory=0

# Include the manual in the tarball.
dist_html_DATA = manual.html
dist_pdf_DATA = manual.pdf

manual.html: $(DOCBOOK_FILES)
	if test "$(XSLTPROC)" != ""; then				\
		$(XSLTPROC) --nonet --xinclude --output manual.html	\
	 	   $(docbookxsl)/html/docbook.xsl manual.xml;		\
	else								\
		echo "Please install xsltproc and rerun configure.";	\
		exit 1;							\
	fi

manual.pdf : $(DOCBOOK_FILES)
	if test "$(DBLATEX)" != ""; then \
	        $(DBLATEX) $(dblatex_opts) manual.xml; \
	else \
	        echo "Please install dblatex and rerun configure."; \
	        exit 1; \
	fi

install-data-local:
	$(INSTALL) -d $(DESTDIR)$(datadir)/doc/hydra/manual
	$(INSTALL_DATA) manual.pdf $(DESTDIR)$(datadir)/doc/hydra/manual
