defmodule PhoenixKitStaff.Errors do
  @moduledoc """
  Atom → translated-string dispatcher for Staff context errors.

  Context functions return `{:error, atom}` (or `{:error, %Ecto.Changeset{}}`
  for changeset errors); LiveViews call `Errors.message/1` at the
  presentation boundary to translate the atom into a flash-ready
  user-facing string.

  Keeping the dispatcher here means:

  1. Translation files only need to know about the literal strings in
     this module — the gettext extractor sees the literals at the
     `gettext(...)` call site of each branch.
  2. Context functions stay storage-agnostic (no `gettext` calls in
     `lib/phoenix_kit_staff/staff.ex`); LiveViews are the one place
     that turns intent into copy.
  3. Future changes to wording happen in one place; new error
     conditions get a new atom + a new branch here.
  """

  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  @typedoc """
  Atoms that the Staff context returns inside `{:error, atom}` tuples.
  Adding a new atom requires adding a `message/1` branch below — the
  `not_found` fallback then never fires for known shapes.
  """
  @type error_atom ::
          :blank_email
          | :placeholder_already_claimed
          | :email_already_taken
          | :not_found

  @doc """
  Translates a Staff error atom into a user-facing message.

  Defaults to a generic fallback for unknown atoms so that callers
  always get a renderable string (no raised pattern-match) — but a
  fallback that fires in production is a sign that a context fn
  returned an atom this module doesn't know about, and should be
  added here.
  """
  @spec message(error_atom() | atom()) :: String.t()
  def message(:blank_email), do: gettext("Email is required.")

  def message(:placeholder_already_claimed),
    do: gettext("This user has already claimed their account — email cannot be changed here.")

  def message(:email_already_taken),
    do: gettext("An account with that email already exists.")

  def message(:not_found), do: gettext("Record not found.")

  def message(other) do
    Logger.warning(
      "[Staff] Errors.message/1 fallback fired for unknown atom: #{inspect(other)} — " <>
        "either add a branch in PhoenixKitStaff.Errors or stop returning this atom from a context fn"
    )

    gettext("Something went wrong. Please try again.")
  end
end
