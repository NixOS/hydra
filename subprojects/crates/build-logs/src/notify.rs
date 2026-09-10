//! Payloads of the `PostgreSQL` notifications the queue runner sends
//! about build steps; the inverses of `notify_step_started`,
//! `notify_step_finished` and `notify_build_finished` in the `db` crate.

/// `step_started`: `"<build_id>\t<step_nr>"`.
pub fn parse_step_started_payload(payload: &str) -> Option<(u64, u64)> {
    let parts: Vec<&str> = payload.split('\t').collect();
    if parts.len() < 2 {
        return None;
    }
    Some((parts[0].parse().ok()?, parts[1].parse().ok()?))
}

pub fn parse_step_finished_payload(payload: &str) -> Option<(u64, u64)> {
    let parts: Vec<&str> = payload.split('\t').collect();
    if parts.len() < 3 {
        return None;
    }
    Some((parts[0].parse().ok()?, parts[1].parse().ok()?))
}

pub fn parse_build_finished_payload(payload: &str) -> Vec<u64> {
    payload.split('\t').filter_map(|s| s.parse().ok()).collect()
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn parse_step_finished_valid() {
        let result = parse_step_finished_payload("42\t5\tlogfile");
        assert_eq!(result, Some((42, 5)));
    }

    #[test]
    fn parse_step_finished_too_few_parts() {
        let result = parse_step_finished_payload("42");
        assert!(result.is_none());
    }

    #[test]
    fn parse_step_finished_invalid_ids() {
        let result = parse_step_finished_payload("abc\t5\tlog");
        assert!(result.is_none());
    }

    #[test]
    fn parse_build_finished_valid() {
        let result = parse_build_finished_payload("42");
        assert_eq!(result, vec![42]);
    }

    #[test]
    fn parse_build_finished_includes_dependents() {
        let result = parse_build_finished_payload("42\t43\t44");
        assert_eq!(result, vec![42, 43, 44]);
    }

    #[test]
    fn parse_build_finished_invalid_payload_is_empty() {
        assert!(parse_build_finished_payload("").is_empty());
        assert!(parse_build_finished_payload("not-an-id").is_empty());
    }

    #[test]
    fn step_started_valid() {
        assert_eq!(parse_step_started_payload("42\t5"), Some((42, 5)));
    }

    #[test]
    fn step_started_too_few_parts() {
        assert_eq!(parse_step_started_payload("42"), None);
    }
}
