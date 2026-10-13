//! The phone-link snapshot and decision hub shared by hosts.
//!
//! The host publishes snapshots and implements [`hub::Host`] to receive decisions.
//! The transport authenticates connections and supplies the capabilities each
//! connection was offered. This crate opens no sockets, starts no runtime, and
//! accesses no keystore; the desktop adapter retains those responsibilities.

pub mod hub;
