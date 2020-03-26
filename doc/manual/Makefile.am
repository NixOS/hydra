DOCBOOK_FILES = installation.xml introduction.xml manual.xml projects.xml hacking.xml

EXTRA_DIST = $(DOCBOOK_FILES)

xsltproc_opts =					\
 --param callout.graphics.extension \'.gif\'	\
 --param section.autolabel 1 			\
 --param section.label.includes.component.label 1


# Include the manual in the tarball.
dist_html_DATA = manual.html

# Embed Docbook's callout images in the distribution.
EXTRA_DIST += images

manual.html: $(DOCBOOK_FILES)
	$(XSLTPROC) $(xsltproc_opts) --nonet --xinclude		\
	  --output manual.html					\
	  $(docbookxsl)/xhtml/docbook.xsl manual.xml

images:
	$(MKDIR_P) images/callouts
	cp $(docbookxsl)/images/callouts/*.gif images/callouts
	chmod +wx images images/callouts

install-data-hook: images
	$(INSTALL) -d $(DESTDIR)$(htmldir)/images/callouts
	$(INSTALL_DATA) images/callouts/* $(DESTDIR)$(htmldir)/images/callouts
	ln -sfn manual.html $(DESTDIR)$(htmldir)/index.html

distclean-hook:
	-rm -rf images
