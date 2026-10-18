//! `Mutex::lock` that gives the guard back even when the mutex is poisoned.
//! Poisoning means one holder panicked mid-write; that bug must not take every
//! later lock down with it — a companion that stops answering after one bad
//! frame is worse than a cache that kept a half-written value.

use std::sync::{Mutex, MutexGuard};

pub trait MutexExt<T> {
    /// Locks, recovering the guard from a poisoned mutex.
    fn lock_recover(&self) -> MutexGuard<'_, T>;
}

impl<T> MutexExt<T> for Mutex<T> {
    fn lock_recover(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(|e| e.into_inner())
    }
}
