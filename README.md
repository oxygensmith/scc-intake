# SCC Intake Portal

## What this is

A small web app for the Saskatoon CarShare Cooperative (SCC) that replaces the "Google Sheet + email chain" used to track new-member onboarding. Owner/operator: Rob (Administrative and Maintenance Coordinator).

Goals, in priority order:

1. **Coordinator dashboard.** One row per applicant, with task-style views instead of a wide spreadsheet.
2. **Applicant self-service.** Applicants log in (magic link), see their own checklist, upload documents, and eventually complete the attestation themselves.
3. **A more secure-feeling drop-off** than emailing licence photos.

Out of scope for v1: automating entry into Engage (see below).

## Context

- **Engage** is the car-share admin system. It only knows members _after_ approval. It tracks nothing about intake. Whether it has an import or API is **unknown**; do not build toward it.
- Intake currently happens via a **Google Form**, which sends people off the Squarespace site.
- The co-op site is on **Squarespace, lowest tier (verify: Basic)**. On that tier, code blocks allow only HTML/CSS (no JS, no iframes), so the portal **cannot be embedded**. The Squarespace site links to it with a plain button.
- Pipeline stages: **Applied → Approved → Paperwork → Deposit → Orientation → In Engage**.
- Real-world examples of what the coordinator view must surface:
  - "Felicia S. — attestation not submitted."
  - "Sandy F. — missing membership fee, abstract, attestation."
  - "Eddie G. — needs fob mailed."

## Stack (decided)

- **Frontend:** static site on **Netlify**, at `forms.saskatooncarshare.com` (preferred; avoid `*.netlify.app` for a page collecting personal info). Branded to match the Squarespace site.
- **Backend:** **Supabase**: Postgres, Auth (magic link, no passwords), Storage (private bucket), RLS.
- **Optional:** Netlify Functions only if a secret must be kept server-side. The Supabase `service_role` key never goes in front-end code.

## Data model (draft; refine with Rob)

`applicants`

- `id`, `user_id` (links to the Supabase auth user), `name`, `email`, `applied_at`
- `stage` (enum of the six stages above)
- Checklist flags with timestamps: `attestation_received_at`, `abstract_received_at`, `fee_received_at`, `orientation_done_at`, `fob_mailed_at`, `in_engage_at`
- `licence_verified_at` + `licence_verified_by`; `abstract_verified_at` + `abstract_verified_by`
- `notes` (coordinator-only)
- Derived (view or computed): `waiting_on` (applicant or coordinator) and `outstanding` (text list of missing items)

Roles: `applicant`, `coordinator`, `board`. Decide with Rob whether board is read-only (likely).

Verify the real checklist steps with Rob before finalizing columns; the list above is inferred from a conversation, not from the actual process.

## Coordinator views (the point of the app)

- **Needs action (me):** waiting_on = coordinator (e.g. fob to mail).
- **Chasing applicants:** waiting_on = applicant, oldest first.
- **Board overview:** grouped by stage; read-only.

## Security requirements (non-negotiable)

- **RLS enabled on every table, with explicit policies.** Never rely on the default. Check each table, including any created by raw SQL migrations.
  - Applicant: read/update only their own row, and only the fields they're meant to change.
  - Coordinator: full access.
  - Board: read-only (confirm).
- **Storage has its own policies**, separate from table RLS. Private bucket only. Applicants can write to their own folder; they can't read other people's files.
- Files are opened by coordinators via **short-lived signed URLs**, never public URLs.
- **Write adversarial tests:** log in as applicant A and try to read applicant B's row and files. Do the same with the anon key and no login. Report results to Rob.
- Create the Supabase project in a **Canadian region** if one is available (verify; regions are hard to change later).
- Don't log or echo personal data in client console output or error messages.

## Document handling: view, verify, delete

Current practice, to be **confirmed with Ed (outgoing coordinator) before the UI text is written**: licence photos are viewed and **not retained**. Design for that:

- Upload goes to a private bucket as a temporary hand-off.
- When the coordinator marks a document "verified," the app records who and when, **and deletes the file in the same action.**
- Backstop: a scheduled job deletes any upload older than N days (suggest 30).
- Store confirmations and dates only. Don't store licence numbers or transcribe abstract contents.
- Upload page shows one honest line about this ("We view this to verify it, then delete it"). **Write it only once the practice is confirmed.**

Open: does the insurer (contact: Jacqueline) need copies, or only member details? Does the abstract follow the same rule? Ask before building the delete flow.

## E-attestation

Technically: a checkbox plus the exact wording agreed to, a timestamp, and the logged-in identity. Whether that satisfies what the attestation is _for_ (bylaws, insurer, board) is **unconfirmed. Do not build it until Rob confirms it's acceptable.**

## Build order

1. Schema + RLS + auth. Seed with fake data only.
2. Coordinator dashboard (the three views).
3. Applicant login and status page.
4. Document upload + verify-and-delete flow (after retention question is answered).
5. E-attestation (after board confirms).
6. Intake form that creates the applicant record, replacing the Google Form. Link to it from Squarespace via a button.

Engage integration is **not** on this list.

## Ownership and handoff (important)

The coordinator role turns over. Everything must survive that:

- Supabase project, Netlify site, domain/DNS, and the GitHub repo are owned under a **co-op email/organization**, not Rob's personal accounts. Raise this at project creation; don't defer it.
- Keep the stack boring and documented.
- Rob writes SOPs in the Moonjoule Notion ("SOPs + Best Practices"). Produce a short operations SOP at the end: how to add a coordinator, rotate keys, restore from backup, and what the delete job does.
- No real applicant data in the repo, ever. `.env` files are gitignored; supply an `.env.example`.
