# Local action broker (not connected)

`ACTALocalActionBroker` is an isolated opt-in foundation, not production
authorization. Existing chat, voice, GUI and scheduled work still use their
current paths; direct domain calls and the legacy shared registry are not
protected by this broker.

The intended UX is that model-requested inspections run only in a scoped local
session, while **every model-requested mutation needs operator approval**.
The model sees only that approval is required, not the review handle, token,
title or parameters. GUI/domain operations retain their existing behavior;
schedules and other initiators must not be assigned a broker session until
separately authorized.

Trusted host code must retain the operator and session capabilities in process,
restrict each session to explicit action IDs and a trusted thread, intersect
model calls with the actual request catalogue, and provide a durable audit
sink. Audit events do not contain parameter values. Failed pre-execution audit
prevents execution; failed post-execution audit reports that execution may have
occurred. Inspection output still requires action-specific privacy review.

`ACTABrokerReviewView` is a separate trusted UI component: it displays the
complete title, thread, action and parameters in an unambiguous escaped form,
requires an explicit acknowledgement before approval, and can reject without
acknowledgement. Values with URL-like content, sensitive field names, or
excessive size are rejected before execution. These heuristics do not identify
every possible secret; the view must remain private and the host must not log,
persist or send its review to the model. Review approval does not prove a human
saw the display.

**Integration blocker:** the existing production GUI and legacy confirmation
paths do not use this component or broker; they expose only redacted details.
Connecting only this view would leave shared-registry and legacy identity paths
able to bypass it. Production integration must migrate all model execution and
confirmation paths together, validate inspection output privacy, and retain
trusted classifications and domain-level freshness checks. Approval of
parameters alone is not a state snapshot.

Capabilities are not an OS security boundary. Closing a session revokes future
work; it cannot undo an operation already started. Reviews are in-memory and
expire conservatively, and are lost on process restart.
