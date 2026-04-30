defmodule PhoenixKitStaff.Web.Helpers do
  @moduledoc """
  Cross-LV helpers shared by the staff admin LiveViews.

  ## `log_operation_error/3` — failure-side audit rows

  Staff's documented architectural choice is that **`PhoenixKitStaff.Activity`
  is success-only at the call site** (see `CLAUDE.md` "Activity logging").
  The post-Apr pipeline expects every user-driven mutation to leave an
  audit row on BOTH `:ok` AND `:error` branches so a DB outage / FK
  violation / constraint failure can't silently erase admin clicks
  from the activity feed.

  The catalogue module's Batch 4 (canonical reference at
  `phoenix_kit_catalogue/lib/phoenix_kit_catalogue/web/helpers.ex`)
  resolves the tension by writing the failure-side row at the
  **LiveView layer**, not in the context. Same intent here:

  - One edit point in this helper instead of ~10 LV mutation sites
  - Same action atom the success path would have used
    (e.g. `staff.person_deleted`)
  - `metadata.db_pending: true` so audit-feed readers can distinguish
    attempted-but-failed from completed actions
  - PII-safe metadata: changeset reasons land error-key field names
    only (no values), atom reasons land the atom string, other shapes
    get `error_kind: "other"`

  Helper only fires from `handle_event` `{:error, _}` branches —
  validate cycles never reach it (they're handled by the form's
  `assign_form/2` cycle, no audit row needed for keystrokes).
  """

  alias PhoenixKitStaff.Activity

  @doc """
  Writes a failure-side activity row for a destructive/mutating operation.

  ## Required opts

    * `:resource_type` — string, e.g. `"staff_person"` / `"department"`
    * `:reason` — the `{:error, reason}` value from the context call

  ## Optional opts

    * `:resource_uuid` — uuid of the record the operation targeted.
      Optional because failed CREATE submissions have no uuid yet — in
      that case the audit row records intent without a target.
    * `:target_uuid` — second-party uuid for membership operations
      (the user being added/removed, etc.)
    * `:metadata` — extra metadata (must be PII-safe). Merged UNDER
      the helper's own `db_pending` / `error_kind` / `error_keys` /
      `error_atom` keys — caller-supplied collisions on those keys are
      ignored so the audit-feed contract stays stable.

  Returns the underlying `Activity.log/2` return value (`:ok`,
  `{:ok, _entry}`, `{:error, _}`, `:activity_unavailable`); never
  raises.
  """
  @spec log_operation_error(String.t(), Phoenix.LiveView.Socket.t(), keyword()) ::
          :ok | :activity_unavailable | {:ok, struct()} | {:error, any()}
  def log_operation_error(action, socket, opts) when is_binary(action) and is_list(opts) do
    reason = Keyword.fetch!(opts, :reason)
    resource_type = Keyword.fetch!(opts, :resource_type)
    resource_uuid = Keyword.get(opts, :resource_uuid)
    target_uuid = Keyword.get(opts, :target_uuid)
    extra_metadata = Keyword.get(opts, :metadata, %{})

    helper_metadata = Map.put(reason_metadata(reason), "db_pending", true)

    # Caller metadata first; helper-owned keys win. Audit-feed readers
    # rely on `db_pending` / `error_kind` so callers must not override.
    metadata =
      extra_metadata
      |> stringify_keys()
      |> Map.merge(helper_metadata)

    Activity.log(action,
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: resource_type,
      resource_uuid: resource_uuid,
      target_uuid: target_uuid,
      metadata: metadata
    )
  end

  # PII-safe reason summarisation. Changeset error keys are field
  # names (safe); changeset error MESSAGES often interpolate user
  # input (unsafe — never logged). Atom reasons get stringified.
  # Anything else lands as "other".
  defp reason_metadata(%Ecto.Changeset{errors: errors}) do
    %{
      "error_kind" => "changeset",
      "error_keys" => Enum.map(errors, fn {field, _err} -> Atom.to_string(field) end)
    }
  end

  defp reason_metadata(reason) when is_atom(reason) do
    %{"error_kind" => "atom", "error_atom" => Atom.to_string(reason)}
  end

  defp reason_metadata(_other), do: %{"error_kind" => "other"}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(other), do: other
end
