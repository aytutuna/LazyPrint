use lazy_ipp::retry::RetryPolicy;
use std::time::Duration;

#[test]
fn a_policy_whose_first_wait_exceeds_its_largest_does_not_panic() {
    let policy = RetryPolicy {
        initial_delay: Duration::from_secs(10),
        max_delay: Duration::from_secs(2),
        ..Default::default()
    };
    assert_eq!(
        policy.delay_before(0, Some(Duration::from_secs(1))),
        Duration::from_secs(2)
    );
    assert_eq!(policy.delay_before(0, None), Duration::from_secs(2));
}
