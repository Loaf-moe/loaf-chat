//! Loaf Chat for Linux, macOS and Windows.

#[cfg_attr(
    test,
    expect(
        clippy::missing_const_for_fn,
        reason = "the test harness makes main an ordinary fn; goes once main has a body"
    )
)]
fn main() {}
