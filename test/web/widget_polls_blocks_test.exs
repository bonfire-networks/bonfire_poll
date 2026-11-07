defmodule Bonfire.Poll.Web.WidgetPollsBlocksTest do
  @moduledoc "\"Polls closing soon\" is cached once for guests and once for everyone signed in (`Bonfire.Boundaries.Circles.query_as_circle/1`), and drops the polls of whoever each viewer silenced when rendering."
  use Bonfire.Poll.ConnCase, async: false
  import PhoenixTest
  @moduletag :ui

  alias Bonfire.Boundaries.Blocks

  defp closing_poll!(user, name) do
    now = DateTime.utc_now()

    {:ok, poll} =
      fake_question(
        %{
          post_content: %{name: name},
          voting_dates: [DateTime.add(now, -60, :second), DateTime.add(now, 3600, :second)]
        },
        current_user: user,
        boundary: "public"
      )

    poll
  end

  test "everyone signed in shares one cache entry, and guests another" do
    alice = fake_user!()
    bob = fake_user!()

    assert Bonfire.Poll.Questions.closing_soon_cache_key(alice, 3) ==
             Bonfire.Poll.Questions.closing_soon_cache_key(bob, 3)

    refute Bonfire.Poll.Questions.closing_soon_cache_key(alice, 3) ==
             Bonfire.Poll.Questions.closing_soon_cache_key(nil, 3)
  end

  test "drops a poll once I silence its author, and keeps the others" do
    account = fake_account!()
    me = fake_user!(account)
    author = fake_user!(fake_account!())
    bystander = fake_user!(fake_account!())

    closing_poll!(author, "Poll by the author")
    closing_poll!(bystander, "Poll by a bystander")

    # cached once for everyone signed in, so one test's list would otherwise be read by the next
    Bonfire.Poll.Questions.closing_soon_widget(me, 3, cache: :reset)

    on_exit(fn ->
      for viewer <- [me, nil],
          do: Bonfire.Poll.Questions.closing_soon_widget(viewer, 3, cache: :reset)
    end)

    conn = conn(user: me, account: account)

    # the positive first, which also fills the cache
    conn
    |> visit("/dashboard")
    |> wait_async()
    |> assert_has("[data-role=poll_card]", text: "Poll by the author")
    |> assert_has("[data-role=poll_card]", text: "Poll by a bystander")

    Blocks.block(author, :silence, current_user: me)

    conn
    |> visit("/dashboard")
    |> wait_async()
    |> assert_has("[data-role=poll_card]", text: "Poll by a bystander")
    |> refute_has("[data-role=poll_card]", text: "Poll by the author")
  end
end
