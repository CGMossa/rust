SECTIONS
{
  .linkme_PLUGINS : {
    KEEP(*(SORT_BY_NAME(.linkme_PLUGINS$*)))
  }
  .linkm2_PLUGINS : {
    KEEP(*(SORT_BY_NAME(.linkm2_PLUGINS$*)))
  }
} INSERT AFTER .text;
