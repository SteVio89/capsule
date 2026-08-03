//! The closed sets the store is built on.

const std = @import("std");

pub const Issue = struct {
    /// Only `done` is terminal.
    pub const State = enum {
        /// Filed by an agent, awaiting triage. Never dispatched, never shown to an agent.
        proposed,
        open,
        in_progress,
        /// The agent's report that it is stuck. Exists so a stalled run is visible among
        /// several on the dashboard.
        blocked,
        /// The agent's claim that its part is finished — not a decision. The human's
        /// decision is `run merge`.
        ready_for_review,
        /// Reached only by `run merge`. There is no manual close.
        done,
        /// The "not merging this" path. Reversible, so gc must never sweep its branch.
        archived,

        /// The state exactly as spelled in the database column, or null for anything
        /// else.
        pub fn parse(text: []const u8) ?State {
            return std.meta.stringToEnum(State, text);
        }
    };
};

pub const Event = struct {
    pub const Kind = enum {
        created,
        edited,
        renamed,
        state_changed,
        commented,
        filed_by_agent,
        /// Accepted at triage. Rejection is an `archived` event carrying the reason, so
        /// there is no separate rejected state to reason about.
        triaged,
        archived,
        reopened,
        merged,
    };

    pub const Actor = enum { human, agent };

    kind: Kind,
    actor: Actor,
    /// Only read for `state_changed`.
    to: ?Issue.State = null,
};

pub const Run = struct {
    /// `ended` means the user quit; `abandoned` means something broke. Keeping them apart
    /// is the whole point — the dashboard should say which.
    pub const State = enum { active, ended, abandoned };
};

pub const Memory = struct {
    /// `inactive` deliberately covers both "rejected" and "not sure yet". Nothing is
    /// deleted, so a proposal that keeps coming back is visible as such.
    pub const State = enum { proposed, active, inactive };

    /// Enforced, not advisory. Accepting at the cap is refused unless the same review
    /// buffer frees a slot — that refusal is the entire reason curation happens.
    pub const active_cap = 40;

    /// Warns, never blocks. The cap already governs count, so what this detects is
    /// verbosity: 40 memories of one to three sentences comes to roughly 2,000.
    pub const token_budget = 3000;
};
