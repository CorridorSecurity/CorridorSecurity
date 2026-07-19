# Writing a PR review

We write a short review per pull request so a teammate gets a clear
read on whether it's safe and clean to merge. Reviews live at
`.pr-reviews/<number>.md`. The job is to judge the change on
correctness, security, and simplicity, and to flag anything worth a
decision before merge.

Use this prompt to write one:

Read the PR — its description, the diff, and the code around the
changes. Read the tests too. Don't guess; if you can't confirm
something from the code, say so rather than asserting it.

**Wait for the Corridor CI check.** Before writing the review, wait
for the Corridor CI check on the PR to finish and read its findings —
it's a required input, not an optional extra. If it's still running,
hold off; if it errored or never ran, say so in the review rather than
reviewing without it. Treat its findings as one signal to weigh
alongside your own reading of the code.

Open the file with YAML frontmatter pinning what you reviewed, so a
reader (or the auto-approve bot) can tell whether the review still
matches the PR:

---
pr: <number>
branch: <head branch>
reviewed_commit: <full SHA of the code tip you reviewed>
reviewed_at: <YYYY-MM-DD>
verdict: <no major concerns | concerns raised>
---

`reviewed_commit` is the commit whose code you read — pin the current
code tip, then add this review file on top of it. It is **not** the
eventual HEAD (a commit can't contain its own hash). The auto-approve
bot treats the review as fresh only when the sole change between
`reviewed_commit` and HEAD is this review doc; any code commit pushed
afterwards makes it stale, so re-review and re-pin if the code moves.

Then write the review the way you'd talk a colleague through it:

- **Overall** — a couple of sentences on whether it's solid, what it
  does well, and your bottom line. Be honest, not flattering.
- **Duplication of existing features** — check whether the PR
  re-implements a feature, endpoint, util, hook, or flow that already
  exists on `main`.
- **Security** — the part to read closely. Start from the Corridor CI
  check findings (see above) and your own reading of the diff. Number
  the things worth raising and tag each with a rough severity and kind,
  e.g. *(medium / defense-in-depth)*; note which came from the CI check
  and which you found yourself. Explain the concern in plain terms and
  what you'd do about it. Then add a short "correctly handled" list
  confirming the things you checked that are fine — tenant scoping,
  query-level ownership checks, "not found" over "forbidden", wrapping
  user text before a model/Slack, bounded request bodies — so the
  reader knows you looked.
- **Readability** — comment density, naming, duplication, anything
  dense enough to slow a reader down.
- **Performance** — anything that won't scale, clearly marked
  non-blocking if it's fine for the current scope.
- **Test coverage (required for approval)** — new or changed source
  must ship with tests. Treat new or changed source landing without
  adequate unit + e2e coverage as a blocking concern.
- **Suggested actions** — a short list: what to fix, what to document
  + ticket, what's optional.

Set `verdict: no major concerns` only when nothing in the review
blocks merge. Otherwise use `concerns raised` and say what would
change your mind.
