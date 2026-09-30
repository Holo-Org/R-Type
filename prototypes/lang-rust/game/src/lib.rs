//! The Game: R-Type's messages and rules, built on the Engine's headless part.
//! It must stay headless, since the Server links it.

pub mod protocol;
/// The rules of a Match (`match` is a Rust keyword, hence the module name).
pub mod rules;
