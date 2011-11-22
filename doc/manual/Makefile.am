DOCBOOK_FILES = installation.xml introduction.xml manual.xml projects.xml

EXTRA_DIST = $(DOCBOOK_FILES)

xsltproc_opts =					\
 --param html.stylesheet \'style.css\'		\
 --param callout.graphics.extension \'.gif\'

dblatex_opts = \
 -V \
 -P doc.collab.show=0 \
 -P latex.output.revhistory=0

# Include the manual in the tarball.
dist_html_DATA = manual.html style.css
dist_pdf_DATA = manual.pdf

# Embed Docbook's callout images in the distribution.
EXTRA_DIST += images

manual.html: $(DOCBOOK_FILES)
	if test "$(XSLTPROC)" != ""; then				\
		$(XSLTPROC) $(xsltproc_opts) --nonet --xinclude		\
	           --output manual.html					\
	 	   $(docbookxsl)/html/docbook.xsl manual.xml;		\
	else								\
		echo "Please install xsltproc and rerun configure.";	\
		exit 1;							\
	fi

manual.pdf: $(DOCBOOK_FILES)
	if test "$(DBLATEX)" != ""; then \
	        $(DBLATEX) $(dblatex_opts) manual.xml \
	else \
	        echo "Please install dblatex and rerun configure."; \
	        exit 1; \
	fi

images:
	$(MKDIR_P) images/callouts
	if cp $(docbookxsl)/images/callouts/*.gif images/callouts; then	\
		chmod +wx images images/callouts;			\
	else								\
		echo "Please install Docbook XSL and try again.";	\
		exit 1;							\
	fi

install-data-hook: images
	$(INSTALL) -d $(DESTDIR)$(htmldir)/images/callouts
	$(INSTALL_DATA) images/callouts/* $(DESTDIR)$(htmldir)/images/callouts

distclean-hook:
	-rm -rf images
