#![crate_type = "staticlib"]

#[used]
#[unsafe(link_section = ".mytest$b")]
#[unsafe(no_mangle)]
pub static EXT_ELEM: u64 = 0xBBBB0001;

#[used]
#[unsafe(link_section = ".mytest$b")]
static LOCAL_ELEM: u64 = 0xBBBB0002;

#[unsafe(no_mangle)]
pub extern "C" fn touch() -> u64 { 42 }
