DOCBOOK_FILES = installation.xml introduction.xml manual.xml

dblatex_opts = \
 -P doc.collab.show=0 \
 -P latex.output.revhistory=0

manual.pdf : $(DOCBOOK_FILES)
	dblatex $(dblatex_opts) manual.xml

