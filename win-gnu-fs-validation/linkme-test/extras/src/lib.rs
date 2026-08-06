use linkme::distributed_slice;
use plugins::PLUGINS;

// Registered in a crate that nothing ever calls into: exercises
// archive-member pulling (no symbol reference into this object).
#[distributed_slice(PLUGINS)]
static P4: u64 = 0xAAAA0004;
