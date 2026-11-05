# PR #5 — Document Person.work_schedule: review record

**Author:** Max Don
**Reviewer:** Claude (Opus 5.5)
**Merge:** `8628d4e`
**Verdict:** no findings. Documentation only.

Adds a planned-field note to `AGENTS.md`. Nothing reads or writes `work_schedule` in staff or projects, so it stays what it claims to be: a plan. The shape it proposed (`null` for non-working days, a Mon-Fri fallback) was superseded by #6; the current `AGENTS.md` TODO follows #6.
