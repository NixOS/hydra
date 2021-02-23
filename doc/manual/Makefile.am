MD_FILES = src/*.md

EXTRA_DIST = $(MD_FILES)

install: $(MD_FILES)
	mdbook build . -d $(docdir)
