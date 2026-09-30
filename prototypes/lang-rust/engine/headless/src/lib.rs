//! The Engine's headless part: what both the Server and the Clients need, and
//! nothing that draws, plays sound or reads a keyboard. Like all of the Engine,
//! it knows nothing about R-Type (ADR 0001).

pub mod bytes;
pub mod net;
pub mod random;
pub mod time;
