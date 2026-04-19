defmodule PhoenixKitStaff.StaffTest do
  use ExUnit.Case, async: true

  alias PhoenixKitStaff.Staff

  describe "valid_email?/1" do
    test "accepts well-formed addresses" do
      assert Staff.valid_email?("alice@example.com")
      assert Staff.valid_email?("a.b+c@sub.example.co.uk")
    end

    test "rejects malformed addresses" do
      refute Staff.valid_email?("")
      refute Staff.valid_email?("plain")
      refute Staff.valid_email?("no@tld")
      refute Staff.valid_email?("@nouser.com")
      refute Staff.valid_email?("has spaces@example.com")
    end

    test "non-binary input is rejected safely" do
      refute Staff.valid_email?(nil)
      refute Staff.valid_email?(123)
    end
  end

  describe "email_regex/0" do
    test "is a compiled regex" do
      assert %Regex{} = Staff.email_regex()
    end

    test "matches a typical email" do
      assert Regex.match?(Staff.email_regex(), "x@y.z")
    end
  end
end
