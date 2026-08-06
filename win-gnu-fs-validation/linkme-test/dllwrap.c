#include <stddef.h>
extern size_t plugin_count(void);
extern unsigned long long plugin_sum(void);
__declspec(dllexport) size_t pkg_count(void) { return plugin_count(); }
__declspec(dllexport) unsigned long long pkg_sum(void) { return plugin_sum(); }
