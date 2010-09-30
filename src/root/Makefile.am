TEMPLATES = $(wildcard *.tt) 
STATIC = \
  $(wildcard static/images/*) \
  $(wildcard static/css/*)

FLOT = flot-0.6.zip 
TABLESORTER = jquery.tablesorter.zip 
JQUERY = jquery-ui-1.8.5.custom.zip

ZIPS = $(FLOT) $(TABLESORTER) $(JQUERY)

EXTRA_DIST = $(TEMPLATES) $(STATIC) $(ZIPS)

hydradir = $(libexecdir)/hydra/root
nobase_hydra_DATA = $(EXTRA_DIST)
  
install-data-local: $(ZIPS)
	mkdir -p $(hydradir)/static/js
	unzip -u -d $(hydradir)/static/js/jquery $(JQUERY)
	rm -rf $(hydradir)/static/js/tablesorter
	unzip -u -d $(hydradir)/static/js $(TABLESORTER)
	unzip -u -d $(hydradir)/static/js $(FLOT)

