// Model cache policy, independent of sherpa and audio devices so the idle
// boundary and ownership rules can be tested without downloading a model.
use std::sync::Arc;
use std::time::{Duration, Instant};

pub(super) const IDLE_TIMEOUT: Duration = Duration::from_secs(5 * 60);

pub(super) struct IdleCache<T> {
    value: Option<Arc<T>>,
    last_used: Option<Instant>,
}

impl<T> IdleCache<T> {
    pub fn new() -> Self {
        Self { value: None, last_used: None }
    }

    pub fn is_loaded(&self) -> bool {
        self.value.is_some()
    }

    pub fn get(&mut self, now: Instant) -> Option<Arc<T>> {
        let value = self.value.as_ref()?.clone();
        self.last_used = Some(now);
        Some(value)
    }

    pub fn set(&mut self, value: Option<Arc<T>>, now: Instant) {
        self.last_used = value.as_ref().map(|_| now);
        self.value = value;
    }

    pub fn take(&mut self) -> Option<Arc<T>> {
        self.last_used = None;
        self.value.take()
    }

    pub fn take_if_idle(&mut self, now: Instant, busy: bool) -> Option<Arc<T>> {
        let value = self.value.as_ref()?;
        // An inference caller may own the model even before a UI phase changes.
        // Never evict that cache entry and trigger a second load alongside it.
        if busy || Arc::strong_count(value) > 1 {
            self.last_used = Some(now);
            return None;
        }
        let last = self.last_used?;
        if now.saturating_duration_since(last) < IDLE_TIMEOUT {
            return None;
        }
        self.take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_cache_has_nothing_to_evict() {
        let mut cache = IdleCache::<()>::new();
        assert!(cache.take_if_idle(Instant::now(), false).is_none());
        assert!(!cache.is_loaded());
    }

    #[test]
    fn the_model_is_kept_until_the_idle_boundary_then_evicted_once() {
        let now = Instant::now();
        let mut cache = IdleCache::new();
        cache.set(Some(Arc::new(())), now);
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT - Duration::from_millis(1), false).is_none());
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT, false).is_some());
        assert!(!cache.is_loaded());
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT, false).is_none());
    }

    #[test]
    fn accessing_the_model_restarts_the_idle_deadline() {
        let now = Instant::now();
        let mut cache = IdleCache::new();
        cache.set(Some(Arc::new(())), now);
        drop(cache.get(now + Duration::from_secs(60)));
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT, false).is_none());
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT + Duration::from_secs(60), false).is_some());
    }

    #[test]
    fn busy_voice_dictation_or_recording_keeps_the_cache_warm() {
        let now = Instant::now();
        let mut cache = IdleCache::new();
        cache.set(Some(Arc::new(())), now);
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT, true).is_none());
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT + Duration::from_secs(1), false).is_none());
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT * 2, false).is_some());
    }

    #[test]
    fn an_active_inference_owner_prevents_eviction_even_without_a_busy_flag() {
        let now = Instant::now();
        let mut cache = IdleCache::new();
        cache.set(Some(Arc::new(())), now);
        let owner = cache.get(now).unwrap();
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT, false).is_none());
        drop(owner);
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT + Duration::from_secs(1), false).is_none());
        assert!(cache.take_if_idle(now + IDLE_TIMEOUT * 2, false).is_some());
    }

    #[test]
    fn unloading_does_not_destroy_an_active_callers_model() {
        let now = Instant::now();
        let mut cache = IdleCache::new();
        cache.set(Some(Arc::new(42)), now);
        let owner = cache.get(now).unwrap();
        drop(cache.take());
        assert_eq!(*owner, 42);
        assert!(!cache.is_loaded());
        assert!(cache.get(now).is_none());
        cache.set(Some(Arc::new(43)), now);
        assert_eq!(*cache.get(now).unwrap(), 43);
    }
}
