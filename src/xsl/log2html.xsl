<?xml version="1.0"?>

<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">

  <xsl:output method='html' encoding="UTF-8"
              doctype-public="-//W3C//DTD HTML 4.01//EN"
              doctype-system="http://www.w3.org/TR/html4/strict.dtd" />

  <xsl:template match="logfile">
    <p>
    <a href="javascript:" class="btn btn-info tree-expand-all"><i class="icon-plus icon-white"></i> Expand all</a>
    <xsl:text> </xsl:text>
    <a href="javascript:" class="btn btn-info tree-collapse-all"><i class="icon-minus icon-white"></i> Collapse all</a>
    </p>
    <ul class='tree'>
      <xsl:for-each select='line|nest'>
        <li>
          <xsl:apply-templates select='.'/>
        </li>
      </xsl:for-each>
    </ul>
  </xsl:template>


  <xsl:template match="nest">

    <!-- The tree should be collapsed by default if all children are
         unimportant or if the header is unimportant. -->
<!--    <xsl:variable name="collapsed"
                  select="count(.//line[not(@priority = 3)]) = 0 or ./head[@priority = 3]" /> -->
    <xsl:variable name="collapsed" select="count(.//*[@error]) = 0"/>

    <xsl:variable name="style"><xsl:if test="$collapsed">display: none;</xsl:if></xsl:variable>
    <xsl:variable name="arg"><xsl:choose><xsl:when test="$collapsed">true</xsl:when><xsl:otherwise>false</xsl:otherwise></xsl:choose></xsl:variable>

    <xsl:if test="line|nest">
      <a href="javascript:" class="tree-toggle"></a>
      <xsl:text> </xsl:text>
    </xsl:if>

    <xsl:apply-templates select='head'/>

    <!-- Be careful to only generate <ul>s if there are <li>s, otherwise it’s malformed. -->
    <xsl:if test="line|nest">

      <ul class='subtree' style="{$style}">
        <xsl:for-each select='line|nest'>
          <li class='tree-line'>
            <span class='tree-conn' />
            <xsl:apply-templates select='.'/>
          </li>
        </xsl:for-each>
      </ul>
    </xsl:if>

  </xsl:template>


  <xsl:template match="head|line">
    <span class="code">
      <xsl:if test="@error">
        <xsl:attribute name="class">code errorLine</xsl:attribute>
      </xsl:if>
      <xsl:if test="@warning">
        <xsl:attribute name="class">code warningLine</xsl:attribute>
      </xsl:if>
      <xsl:if test="@priority = 3">
        <xsl:attribute name="class">code prio3</xsl:attribute>
      </xsl:if>
      <xsl:apply-templates/>
    </span>
  </xsl:template>


  <xsl:template match="storeref">
    <em class='storeref'>
      <span class='popup'><xsl:apply-templates/></span>
      <span class='elided'>/...</span><xsl:apply-templates select='name'/><xsl:apply-templates select='path'/>
    </em>
  </xsl:template>

</xsl:stylesheet>
