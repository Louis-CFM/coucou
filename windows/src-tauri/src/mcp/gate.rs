// The decision rule for MCP tool approvals, kept free of Tauri so it can be
// tested on its own (approval.rs wires it to the island).
//
// Fail closed: a tool that changes things runs only on an Allow clicked before
// the request's deadline. No card, no ack, a declined card, Deny, a timeout, a
// closed channel or a late Allow are all refusals.

use tokio::sync::mpsc;
use tokio::time::{Duration, Instant};

/// What the island says about one MCP approval request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reply {
    /// The card is on screen and a human can act on it.
    Ack,
    /// A human clicked; `at` is when the click reached Coucou.
    Answer { allow: bool, at: Instant },
    /// Nobody can act on it: the island is paused or its line is full.
    Decline,
}

/// An Allow counts only when it arrived strictly before the deadline.
pub fn approves(reply: &Reply, deadline: Instant) -> bool {
    matches!(reply, Reply::Answer { allow: true, at } if *at < deadline)
}

/// Two waits, as for the relay's requests: a short one for "the card is up",
/// then the long one for a human. The deadline is fixed when the request starts,
/// so repeated acks cannot stretch it.
pub async fn wait(rx: &mut mpsc::Receiver<Reply>, ack: Duration, decision: Duration) -> bool {
    let deadline = Instant::now() + decision;
    match tokio::time::timeout(ack, rx.recv()).await {
        Ok(Some(Reply::Ack)) => {}
        // A click that beats the ack is still a click.
        Ok(Some(reply @ Reply::Answer { .. })) => return approves(&reply, deadline),
        // Declined, closed, or no ack in time: nobody can see the card.
        _ => return false,
    }
    loop {
        match tokio::time::timeout_at(deadline, rx.recv()).await {
            // The island acks again when the same request is re-sent: keep waiting.
            Ok(Some(Reply::Ack)) => continue,
            Ok(Some(reply)) => return approves(&reply, deadline),
            Ok(None) | Err(_) => return false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block_on<T>(f: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    const ACK: Duration = Duration::from_millis(40);
    const LONG: Duration = Duration::from_millis(400);

    fn allow() -> Reply {
        Reply::Answer { allow: true, at: Instant::now() }
    }

    #[test]
    fn an_allow_at_or_after_the_deadline_is_a_refusal() {
        let deadline = Instant::now() + Duration::from_secs(5);
        let early = Reply::Answer { allow: true, at: deadline - Duration::from_millis(1) };
        assert!(approves(&early, deadline));
        assert!(!approves(&Reply::Answer { allow: true, at: deadline }, deadline));
        assert!(!approves(&Reply::Answer { allow: true, at: deadline + Duration::from_millis(1) }, deadline));
    }

    #[test]
    fn only_an_allow_approves() {
        let deadline = Instant::now() + Duration::from_secs(5);
        assert!(!approves(&Reply::Answer { allow: false, at: Instant::now() }, deadline));
        assert!(!approves(&Reply::Ack, deadline));
        assert!(!approves(&Reply::Decline, deadline));
    }

    #[test]
    fn no_ack_in_time_is_a_refusal() {
        let (_tx, mut rx) = mpsc::channel(4);
        assert!(!block_on(wait(&mut rx, ACK, LONG)));
    }

    #[test]
    fn a_declined_card_is_a_refusal() {
        let (tx, mut rx) = mpsc::channel(4);
        tx.try_send(Reply::Decline).unwrap();
        assert!(!block_on(wait(&mut rx, ACK, LONG)));
    }

    #[test]
    fn deny_after_the_ack_is_a_refusal() {
        let (tx, mut rx) = mpsc::channel(4);
        tx.try_send(Reply::Ack).unwrap();
        tx.try_send(Reply::Answer { allow: false, at: Instant::now() }).unwrap();
        assert!(!block_on(wait(&mut rx, ACK, LONG)));
    }

    #[test]
    fn allow_after_the_ack_approves_even_with_repeated_acks() {
        let (tx, mut rx) = mpsc::channel(4);
        tx.try_send(Reply::Ack).unwrap();
        tx.try_send(Reply::Ack).unwrap();
        tx.try_send(allow()).unwrap();
        assert!(block_on(wait(&mut rx, ACK, LONG)));
    }

    #[test]
    fn a_click_that_beats_the_ack_is_still_a_click() {
        let (tx, mut rx) = mpsc::channel(4);
        tx.try_send(allow()).unwrap();
        assert!(block_on(wait(&mut rx, ACK, LONG)));
    }

    #[test]
    fn no_answer_after_the_ack_times_out_as_a_refusal() {
        let (tx, mut rx) = mpsc::channel(4);
        tx.try_send(Reply::Ack).unwrap();
        let started = Instant::now();
        assert!(!block_on(wait(&mut rx, ACK, LONG)));
        assert!(started.elapsed() >= LONG - Duration::from_millis(5));
        drop(tx);
    }

    #[test]
    fn a_closed_channel_is_a_refusal() {
        let (tx, mut rx) = mpsc::channel::<Reply>(4);
        tx.try_send(Reply::Ack).unwrap();
        drop(tx);
        assert!(!block_on(wait(&mut rx, ACK, LONG)));
    }

    #[test]
    fn an_allow_stamped_past_the_deadline_is_refused_even_if_read_in_time() {
        let (tx, mut rx) = mpsc::channel(4);
        tx.try_send(Reply::Ack).unwrap();
        tx.try_send(Reply::Answer { allow: true, at: Instant::now() + LONG + Duration::from_secs(1) }).unwrap();
        assert!(!block_on(wait(&mut rx, ACK, LONG)));
    }

    #[test]
    fn a_decline_after_the_ack_is_a_refusal() {
        let (tx, mut rx) = mpsc::channel(4);
        tx.try_send(Reply::Ack).unwrap();
        tx.try_send(Reply::Decline).unwrap();
        assert!(!block_on(wait(&mut rx, ACK, LONG)));
    }

    #[test]
    fn a_late_allow_after_repeated_acks_is_refused() {
        let (tx, mut rx) = mpsc::channel(4);
        tx.try_send(Reply::Ack).unwrap();
        tx.try_send(Reply::Ack).unwrap();
        tx.try_send(Reply::Answer { allow: true, at: Instant::now() + LONG + Duration::from_secs(1) }).unwrap();
        assert!(!block_on(wait(&mut rx, ACK, LONG)));
    }

    #[test]
    fn acks_that_keep_coming_do_not_stretch_the_deadline() {
        let (tx, mut rx) = mpsc::channel(64);
        tx.try_send(Reply::Ack).unwrap();
        let acker = std::thread::spawn(move || {
            for _ in 0..50 {
                std::thread::sleep(std::time::Duration::from_millis(20));
                if tx.try_send(Reply::Ack).is_err() { break; }
            }
        });
        let started = std::time::Instant::now();
        assert!(!block_on(wait(&mut rx, ACK, LONG)));
        assert!(started.elapsed() < LONG + Duration::from_millis(300));
        drop(rx);
        acker.join().unwrap();
    }
}
