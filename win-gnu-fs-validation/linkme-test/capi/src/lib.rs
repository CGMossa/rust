use extras as _;
use linkme::distributed_slice;
use plugins::PLUGINS;

#[distributed_slice(PLUGINS)]
static P2: u64 = 0xAAAA0002;

#[distributed_slice(PLUGINS)]
static P3: u64 = 0xAAAA0003;

#[unsafe(no_mangle)]
pub extern "C" fn plugin_count() -> usize {
    PLUGINS.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn plugin_sum() -> u64 {
    PLUGINS.iter().sum()
}
