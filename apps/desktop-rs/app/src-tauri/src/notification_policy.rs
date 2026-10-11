pub(crate) fn show_call_panel(
    status: &str,
    callee: bool,
    dismissed: bool,
) -> bool {
    !dismissed && status == "ringing" && callee
}

pub(crate) fn can_ring(enabled: bool, muted: bool, stopped: bool, expires: u64, now: u64) -> bool {
    enabled && !muted && !stopped && expires > now
}

pub(crate) fn should_alert(
    previous: u64,
    latest: u64,
    unread: i64,
    visible: bool,
    initialized: bool,
) -> bool {
    latest > previous && (unread > 0 || initialized) && !visible
}
#[cfg(test)]
mod tests {
    use super::{can_ring, should_alert, show_call_panel};
    #[test]
    fn call_panel_only_shows_unanswered_incoming_calls() {
        assert!(show_call_panel("ringing", true, false));
        assert!(!show_call_panel("active", true, false));
        assert!(!show_call_panel("ended", true, false));
        assert!(!show_call_panel("ringing", false, false));
        // A late ringing response must not reopen an accepted/dismissed call.
        assert!(!show_call_panel("ringing", true, true));
    }
    #[test]
    fn ringing_stops_for_mute_decision_and_expiry() {
        assert!(can_ring(true, false, false, 150, 100));
        assert!(!can_ring(false, false, false, 150, 100));
        assert!(!can_ring(true, true, false, 150, 100));
        assert!(!can_ring(true, false, true, 150, 100));
        assert!(!can_ring(true, false, false, 100, 100));
    }
    #[test]
    fn sequence_not_unread_count_controls_deduplication() {
        assert!(should_alert(10, 11, 1, false, false));
        assert!(!should_alert(11, 11, 1, false, false));
        assert!(!should_alert(10, 9, 1, false, false));
    }
    #[test]
    fn another_devices_read_cannot_hide_new_arrival() {
        assert!(should_alert(10, 11, 0, false, true));
        assert!(!should_alert(0, 11, 0, false, false));
    }
    #[test]
    fn read_or_visible_chat_does_not_notify() {
        assert!(!should_alert(10, 11, 0, false, false));
        assert!(!should_alert(10, 11, 1, true, false));
        assert!(should_alert(0, 1, 1, false, false));
    }
}
