/* Generic KEEP for all linkme distributed slices on windows-gnu.
   linkme reads slices via start/stop marker symbols, so merging all
   slices into one output section is fine as long as SORT_BY_NAME keeps
   each slice's $a/$b/$c group contiguous and ordered. */
SECTIONS
{
  .linkmekeep : {
    KEEP(*(SORT_BY_NAME(.linkme_*)))
    KEEP(*(SORT_BY_NAME(.linkm2_*)))
  }
} INSERT AFTER .text;
