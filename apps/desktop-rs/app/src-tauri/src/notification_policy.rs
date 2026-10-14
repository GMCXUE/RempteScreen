// Keep message/request bursts and reconnect backlogs quiet on every client.
pub(crate) fn should_sound(last_alert: u64, sent_at: u64, now: u64) -> bool {
    sent_at > 0 && sent_at <= now.saturating_add(5000)
        && now.saturating_sub(sent_at) <= 60000
        && (last_alert == 0 || now < last_alert || now - last_alert >= 10000)
}

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
#[derive(Debug, PartialEq)]
pub(crate) struct MessagePreview { pub seq: u64, pub text: String, pub at: u64 }
pub(crate) fn message_previews(value: &serde_json::Value, viewed: u64) -> Vec<MessagePreview> {
    let mut rows: Vec<_> = value.as_array().into_iter().flatten().filter_map(|r| {
        let seq=r["seq"].as_str()?.parse::<u64>().ok()?;
        if seq<=viewed { return None; }
        Some(MessagePreview {seq,text:r["text"].as_str()?.chars().take(300).collect(),at:r["createdAt"].as_u64()?})
    }).collect();
    rows.sort_by_key(|r|r.seq);rows.dedup_by_key(|r|r.seq);
    if rows.len()>5 {rows.drain(..rows.len()-5);}
    rows
}
#[cfg(test)]
mod tests {
    #[test]
    fn bursts_and_reconnect_backlogs_stay_quiet() {
        let now=1_000_000;
        assert!(super::should_sound(0,now,now));
        assert!(!super::should_sound(now-9999,now,now));
        assert!(super::should_sound(now-10000,now,now));
        assert!(!super::should_sound(0,now-60001,now));
        assert!(!super::should_sound(0,0,now));
        assert!(!super::should_sound(0,now+6000,now));
        assert!(super::should_sound(now+1,now,now));
    }

    use super::{can_ring, should_alert, show_call_panel};
    #[test]
    fn notification_preview_keeps_newest_five_after_local_viewed_sequence() {
        let rows=serde_json::json!((1..=8).map(|n|serde_json::json!({"seq":n.to_string(),"text":"😀".repeat(400),"createdAt":1700000000000u64+n})).collect::<Vec<_>>());
        let result=super::message_previews(&rows,5);assert_eq!(result.iter().map(|r|r.seq).collect::<Vec<_>>(),vec![6,7,8]);
        assert_eq!(result[0].text.chars().count(),300);
        assert_eq!(super::message_previews(&rows,0).len(),5);
        assert!(super::message_previews(&rows,8).is_empty());
    }
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
