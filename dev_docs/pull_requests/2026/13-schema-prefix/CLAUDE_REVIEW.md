# PR #13 — PhoenixKit.SchemaPrefix: review record

**Author:** Max Don
**Reviewer:** Claude (Opus 5.5)
**Merge:** `9ccd006`
**Verdict:** no findings.

All seven table-backed schemas `use PhoenixKit.SchemaPrefix`, and the conformance test holds that.

The risk with this change is a query that bypasses the schema, so that was the check: nothing in `lib/` outside `migrations.ex` runs raw SQL or queries a table by string name, including `roles_lacking/2`, which goes through core's `RolePermission` schema. `migrations.ex` threads its own prefix.

## NITPICK (not changed)

- The conformance test matches the literal `schema "phoenix_kit`, so a schema naming its table through an attribute would escape it. None does today.
- The `~> 1.7.189` pin here was the three-segment form that #15 later guarded against. Superseded.
