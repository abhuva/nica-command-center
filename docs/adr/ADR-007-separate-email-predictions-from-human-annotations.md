# ADR-007: Separate email predictions from human annotations

**Status**: Accepted

**Date**: 2026-10-08

**Participants**: Marc Bielert and Codex-assisted implementation work

## Context

The Email tool already stores fetched message content, deterministic rule
matches, tags, and an `include_state` used to decide which messages may be
projected into the vault. NICA wants to evaluate small local models for spam
classification against this rebuildable local message cache and correct their
predictions to create a labelled dataset.

Model output, deterministic rules, human review, and operational relevance are
different kinds of evidence. Reusing `include_state` or a single `spam_score`
would erase provenance, prevent comparisons between model revisions, and
confuse legitimate-but-irrelevant mail with spam. Although source messages can
normally be fetched again, human corrections cannot be recreated
deterministically.

## Decision

1. `include_state` remains exclusively the vault-export relevance decision.
2. Every model execution is an immutable classification run with model,
   revision, configuration, selection, progress, and failure metadata.
3. Predictions are stored per run with their complete score map and an input
   hash. Running a model never changes message tags, include/exclude state, or
   a remote mailbox.
4. Current human labels are stored separately and every correction also creates
   an append-only label event.
5. The primary spam taxonomy is `ham`, `spam`, and `unsure`. A separate mail-type
   taxonomy distinguishes phishing, newsletters/marketing, transactional mail,
   personal/organisational mail, other mail, and uncertain cases.
6. A stable 20-percent holdout is assigned from the local message identifier.
   Its prediction remains hidden during first review so it can support a less
   biased evaluation.
7. Human annotations are curated sensitive local state. They remain outside Git
   and Nextcloud, but the tool provides an explicit portable annotation export.
   Exporting message content for training is a separate, warned action.
8. Model packages, weights, and caches are optional machine-local dependencies
   below `NICA_STATE_ROOT`; they are not committed or synchronized.
9. Classification is shadow-only in this decision. It does not delete, move,
   label, or report messages on any mail server.

## Consequences

- (+) Multiple models and revisions can be compared on exactly the same data.
- (+) Corrections do not destroy the original prediction and can be audited.
- (+) Existing deterministic rules and export behavior remain unchanged.
- (+) The blind holdout reduces confirmation bias in reported model quality.
- (+) Optional model downloads do not enlarge the command-centre installation.
- (-) Human labels now require deliberate backup because they are not
  reconstructable from the mail servers.
- (-) A training-data export contains confidential mail content and needs
  protected local storage.
- (=) Remote mailbox actions require a later preview/apply decision after model
  quality and provider behavior have been validated.

## Alternatives considered

### Reuse `include_state` as the spam label

Rejected because export relevance and spam are independent. A legitimate
newsletter can be excluded from the vault without being spam.

### Keep only the newest model score on each message

Rejected because it prevents model comparison, obscures changed inputs, and
removes evidence needed to evaluate corrections.

### Train immediately on deterministic rule results

Rejected as the sole ground truth. Rule matches remain useful weak labels, but
sender-based rules can leak into both training and evaluation and overstate
quality.
