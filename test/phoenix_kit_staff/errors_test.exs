defmodule PhoenixKitStaff.ErrorsTest do
  @moduledoc """
  Per-atom EXACT-string assertions on `PhoenixKitStaff.Errors.message/1`.

  Per workspace AGENTS.md: a `is_binary/1`-loop test is a forbidden
  smell — every branch of `message/1` returns a binary by definition.
  Each atom needs the specific translated string pinned, so adding a
  new atom without adding the corresponding `gettext("...")` literal
  breaks here at test time, not later in production.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitStaff.Errors

  describe "message/1" do
    test ":blank_email" do
      assert Errors.message(:blank_email) == "Email is required."
    end

    test ":placeholder_already_claimed" do
      assert Errors.message(:placeholder_already_claimed) ==
               "This user has already claimed their account — email cannot be changed here."
    end

    test ":email_already_taken" do
      assert Errors.message(:email_already_taken) ==
               "An account with that email already exists."
    end

    test ":not_found" do
      assert Errors.message(:not_found) == "Record not found."
    end

    test "unknown atom falls back to the generic message" do
      assert Errors.message(:never_mapped_atom) ==
               "Something went wrong. Please try again."
    end
  end
end
