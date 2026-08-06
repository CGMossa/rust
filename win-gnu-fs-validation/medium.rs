use std::collections::{BTreeMap, HashMap};
use std::fmt::Write as _;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut hm: HashMap<String, usize> = HashMap::new();
    let mut bt: BTreeMap<usize, String> = BTreeMap::new();
    for (i, a) in args.iter().enumerate() {
        hm.insert(a.clone(), i);
        bt.insert(i, a.to_uppercase());
    }
    let mut v: Vec<f64> = (0..1000).map(|i| (i as f64 * 0.37).sin()).collect();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n: f64 = "3.25e-4".parse().unwrap();
    let mut out = String::new();
    write!(out, "{} {} {:.6} {:?}", hm.len(), bt.len(), n * v[500], v.first()).unwrap();
    println!("{out}");

    let r = std::panic::catch_unwind(|| {
        if args.len() > 100 { panic!("too many args: {}", args.len()) }
        args.len()
    });
    println!("{:?}", r.map_err(|_| "panicked"));
}
