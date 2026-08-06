use linkme::distributed_slice;

#[distributed_slice]
pub static PLUGINS: [u64];

// Registered in this crate; nothing in this object is referenced by symbol
// from the staticlib crate, so archive-member pulling is exercised.
#[distributed_slice(PLUGINS)]
static P1: u64 = 0xAAAA0001;
