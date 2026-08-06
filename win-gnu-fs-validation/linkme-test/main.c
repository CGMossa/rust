#include <stdio.h>
#include <stddef.h>
extern size_t plugin_count(void);
extern unsigned long long plugin_sum(void);
int main(void) {
    printf("count=%zu sum=%llx\n", plugin_count(), plugin_sum());
    return plugin_count() == 3 ? 0 : 1;
}
