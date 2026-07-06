defmodule Bonfire.Poll.Web.ComposerButtonStateTest do
  @moduledoc """
  Guards the composer submit-button state machine for polls: the button is
  enabled iff `smart_input_opts[:input_status] == :draft` (set only by the
  `SmartInput:validate` event), and poll controls that bypass validate
  (duration select, add-option, tuning toggles) must not clobber it.

  The composer lives in the sticky `PersistentLive` child LV, so interactions
  go through `find_live_child(view, "persistent")` rather than PhoenixTest.
  """
  use Bonfire.Poll.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    account = fake_account!()
    me = fake_user!(account)
    {:ok, conn: conn(user: me, account: account), me: me}
  end

  defp open_poll_composer(conn) do
    {:ok, view, _html} = live(conn, "/feed/local")
    persistent = find_live_child(view, "persistent")
    assert persistent, "sticky PersistentLive child not found"

    persistent
    |> element("#composer_type_chooser a[phx-click*='CreatePollLive']")
    |> render_click()

    # the type switch routes through PersistentLive's `set` messaging (a
    # send-to-self here); render/1 is a sync call so it's processed by now
    html = render(persistent)
    assert html =~ "smart_input_poll_content"
    persistent
  end

  defp type_question(persistent, text) do
    persistent
    |> element("#smart_input_poll_content form")
    |> render_change(%{
      "_target" => ["post", "post_content", "html_body"],
      "post" => %{"post_content" => %{"html_body" => text}}
    })
  end

  defp submit_enabled?(persistent) do
    assert has_element?(persistent, "#submit_btn")
    not has_element?(persistent, "#submit_btn[disabled]")
  end

  test "typing the question enables the Post button", %{conn: conn} do
    persistent = open_poll_composer(conn)
    refute submit_enabled?(persistent)

    type_question(persistent, "What shall we do?")
    assert submit_enabled?(persistent)
  end

  test "typing only an option (no question) enables the Post button", %{conn: conn} do
    persistent = open_poll_composer(conn)

    persistent
    |> element("#smart_input_poll_content form")
    |> render_change(%{
      "_target" => ["choices", "0", "name"],
      "post" => %{"post_content" => %{"html_body" => ""}},
      "choices" => %{"0" => %{"name" => "Option A"}, "1" => %{"name" => ""}}
    })

    assert submit_enabled?(persistent)
  end

  test "changing the duration doesn't disable an enabled Post button", %{conn: conn} do
    persistent = open_poll_composer(conn)
    type_question(persistent, "What shall we do?")
    assert submit_enabled?(persistent)

    persistent
    |> element("select[name='duration_hours']")
    |> render_change(%{"duration_hours" => "72"})

    assert submit_enabled?(persistent)
  end

  test "adding an option doesn't disable an enabled Post button", %{conn: conn} do
    persistent = open_poll_composer(conn)
    type_question(persistent, "What shall we do?")
    assert submit_enabled?(persistent)

    persistent
    |> element("[data-role=add-proposal-button]")
    |> render_click()

    assert submit_enabled?(persistent)
  end

  test "clearing the question (with empty options) disables the button again", %{conn: conn} do
    persistent = open_poll_composer(conn)
    type_question(persistent, "What shall we do?")
    assert submit_enabled?(persistent)

    type_question(persistent, "")
    refute submit_enabled?(persistent)
  end
end
