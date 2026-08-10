# Biophysics Weekly Update

This repository builds and emails the weekly paper edition without routine
manual work. The public archive and voting interface live in the separate
`bezialemma/website` repository.

## Automated Monday run

`.github/workflows/weekly-update.yml` runs each Monday at 13:00 UTC. It:

1. reuses the week's frozen archive if this is a retry;
2. otherwise fetches arXiv, bioRxiv, journal RSS, and Crossref sources;
3. downloads anonymous reader feedback from the Cloudflare Worker;
4. filters and summarizes papers with Gemini;
5. refuses to publish when Gemini's failure rate exceeds the configured gate;
6. commits the new edition to `PreviousWeeks` before delivery; and
7. asks the Worker to email every active subscriber.

The fetch stage enforces a final seven-day publication window after all sources
are merged. For bioRxiv, this means the original posting date encoded in the DOI,
not the date of a later revision. Papers selected for an earlier email are also
removed before the AI stage so they cannot be sent twice.

Paper-specific featured overrides live in `featured_papers.txt`. Add one stable
identifier per line in `arxiv:`, `doi:`, or normalized `title:` form.

Freezing before delivery means a partially failed email run can be rerun safely:
already-sent subscribers are skipped, failed or newly added subscribers receive
the exact same edition, and the website archive cannot drift from the email.

The website repository polls this archive every six hours and publishes any new
edition automatically.

## Required GitHub secrets

- `GEMINI_API_KEY`
- `NEWSLETTER_API_URL`
- `NEWSLETTER_ADMIN_TOKEN`
- `RESEND_API_KEY` (owner warning emails)
- `RESEND_FROM`
- `WARNING_EMAIL`

The newsletter API URL is currently the Cloudflare Worker URL ending in
`/api/biophysics-weekly`. Its admin token must match the Worker's `ADMIN_TOKEN`.

## Failure behavior

- arXiv or bioRxiv returning no papers stops the run.
- Journal RSS requests retry three times. A persistently unavailable journal is
  recorded in `fetch_warnings.json`; the run stops before freezing or emailing
  the edition, and the owner receives the failed-source details by email.
- Excessive Gemini classification or summary failures stop the run before an
  edition is committed or emailed.
- A delivery failure stops the workflow, but the edition is already frozen, so
  the GitHub **Re-run jobs** action is safe.

Normal successful weeks require no intervention.

## Local preview

With `GEMINI_API_KEY` configured:

```bash
FETCH_CLEAN=1 ./fetch_and_filter_papers.sh
```

This writes ignored local files such as `papers.json`, `paper_scores.json`, and
`papers_final.md`. Production delivery should be performed by GitHub Actions so
freezing, warnings, and idempotency remain intact.
