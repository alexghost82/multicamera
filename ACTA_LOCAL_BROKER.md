# Local action broker (partial integration)

`ACTALocalActionBroker` is connected to local chat and voice inspections and
to the model-requested `canvas.set_presentation`, `canvas.set_filter`,
`canvas.set_arrange_mode`, `canvas.select_cameras` and `analysis.set_section` actions,
and to a minimal read-only `camera.list`. Other model-requested
registry mutations and legacy action confirmations are rejected. Direct GUI
and domain calls and scheduled work are not protected by this broker.

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

**Integration limitation:** local sessions currently receive named inspection
capabilities for all retained cameras, not an operator-selected camera subset.
The review component is used for these window-local actions only. Remaining actions need
their own authorized integration, privacy review and domain-level freshness
checks. Approval of parameters alone is not a state snapshot.

Capabilities are not an OS security boundary. Closing a session revokes future
work; it cannot undo an operation already started. Reviews are in-memory and
expire conservatively, and are lost on process restart.
