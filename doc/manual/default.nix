let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  sources = lib.sourceFilesBySuffices ./. [".xml"];
in
pkgs.stdenv.mkDerivation {
  name = "hydra-manual";

  buildInputs = with pkgs; [ pandoc libxml2 libxslt zip ];

  xsltFlags = ''
    --param section.autolabel 1
    --param section.label.includes.component.label 1
    --param html.stylesheet 'style.css'
    --param xref.with.number.and.title 1
    --param toc.section.depth 3
    --param admon.style '''
    --param callout.graphics.extension '.gif'
  '';

  buildCommand = ''
    ln -s '${sources}/'*.xml .

    # validate against relaxng schema
    xmllint --nonet --xinclude --noxincludenode manual.xml --output manual-full.xml
    ${pkgs.jing}/bin/jing ${pkgs.docbook5}/xml/rng/docbook/docbook.rng manual-full.xml

    dst=$out/share/doc/hydra
    mkdir -p $dst
    xsltproc $xsltFlags --nonet --xinclude \
      --output $dst/manual.html \
      ${pkgs.docbook5_xsl}/xml/xsl/docbook/xhtml/docbook.xsl \
      ./manual.xml

    cp ${./style.css} $dst/style.css

    mkdir -p $dst/images/callouts
    cp "${pkgs.docbook5_xsl}/xml/xsl/docbook/images/callouts/"*.gif $dst/images/callouts/

    mkdir -p $out/nix-support
    echo "doc manual $dst manual.html" >> $out/nix-support/hydra-build-products

    xsltproc $xsltFlags --nonet --xinclude \
      --output $dst/epub/ \
      ${pkgs.docbook5_xsl}/xml/xsl/docbook/epub/docbook.xsl \
      ./manual.xml

    cp -r $dst/images $dst/epub/OEBPS
    echo "application/epub+zip" > mimetype
    zip -0Xq  "$dst/Hydra User's Guide - NixOS community.epub" mimetype
    zip -Xr9D "$dst/Hydra User's Guide - NixOS community.epub" $dst/epub/*
  '';
}
