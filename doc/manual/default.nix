let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;
  sources = lib.sourceFilesBySuffices ./. [".xml"];
in
{
  manual = pkgs.stdenv.mkDerivation {
    name = "hydra-manual";

    buildInputs = with pkgs; [ libxml2 libxslt ];

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
    '';
  };

  manualPDF = pkgs.stdenv.mkDerivation {
    name = "hydra-manual-pdf";

    buildInputs = with pkgs; [ libxml2 libxslt dblatex dblatex.tex ];

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
 
      dst=$out/share/doc/nixos
      mkdir -p $dst
      xmllint --xinclude manual.xml | dblatex -o $dst/manual.pdf - \
        -P doc.collab.show=0 \
        -P latex.output.revhistory=0

      mkdir -p $out/nix-support
      echo "doc-pdf manual $dst/manual.pdf" >> $out/nix-support/hydra-build-products
    '';
  };
}
