defmodule PhoenixKitStaff.AttachmentsTest do
  @moduledoc """
  Unit tests for the pure helpers. The folder/file DB operations require core
  Storage tables (not migrated by the test harness) and are exercised in the
  browser instead.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitStaff.Attachments

  test "root_folder_name is deterministic per person" do
    assert Attachments.root_folder_name("019e-abc") == "staff-person-019e-abc"
  end

  test "file_icon picks an icon by file_type / mime" do
    assert Attachments.file_icon(%{file_type: "image"}) == "hero-photo"
    assert Attachments.file_icon(%{file_type: "video"}) == "hero-film"
    assert Attachments.file_icon(%{file_type: "archive"}) == "hero-archive-box"
    assert Attachments.file_icon(%{mime_type: "application/pdf"}) == "hero-document-text"
    assert Attachments.file_icon(%{file_type: "other"}) == "hero-document"
  end

  test "format_file_size renders human byte counts, nil-safe" do
    assert Attachments.format_file_size(500) == "500 B"
    assert Attachments.format_file_size(1_500) == "1.5 KB"
    assert Attachments.format_file_size(2_000_000) == "2.0 MB"
    assert Attachments.format_file_size(nil) == "—"
  end

  test "list_files on a nil folder is empty (folder not yet created)" do
    assert Attachments.list_files(nil, []) == []
  end
end
