<?xml version="1.0"?>

<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">

  <xsl:output method='html' encoding="UTF-8"
              doctype-public="-//W3C//DTD HTML 4.01//EN"
              doctype-system="http://www.w3.org/TR/html4/strict.dtd" />

  <xsl:template match="logfile">
    [<a href="javascript:" class="logTreeExpandAll">Expand all</a>]
    [<a href="javascript:" class="logTreeCollapseAll">Collapse all</a>]
    <ul class='toplevel'>
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
      <a href="javascript:" class="logTreeToggle"></a>
      <xsl:text> </xsl:text>
    </xsl:if>
    
    <xsl:apply-templates select='head'/>

    <!-- Be careful to only generate <ul>s if there are <li>s, otherwise it’s malformed. -->
    <xsl:if test="line|nest">
      
      <ul class='nesting' style="{$style}">
        <xsl:for-each select='line|nest'>

          <!-- Is this the last line?  If so, mark it as such so that it
               can be rendered differently. -->
          <xsl:variable  name="class"><xsl:choose><xsl:when test="position() != last()">line</xsl:when><xsl:otherwise>lastline</xsl:otherwise></xsl:choose></xsl:variable>
        
          <li class='{$class}'>
            <span class='lineconn' />
            <span class='linebody'>
              <xsl:apply-templates select='.'/>
            </span>
          </li>
        </xsl:for-each>
      </ul>
    </xsl:if>
    
  </xsl:template>

  
  <xsl:template match="head|line">
    <code>
      <xsl:if test="@error">
        <xsl:attribute name="class">error</xsl:attribute>
      </xsl:if>
      <xsl:apply-templates/>
    </code>
  </xsl:template>

  
  <xsl:template match="storeref">
    <em class='storeref'>
      <span class='popup'><xsl:apply-templates/></span>
      <span class='elided'>/...</span><xsl:apply-templates select='name'/><xsl:apply-templates select='path'/>
    </em>
  </xsl:template>
  
</xsl:stylesheet>