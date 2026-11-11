defmodule Bonfire.Poll.Web.WidgetPollsClosingSoonTest do
  @moduledoc "The \"Polls closing soon\" widget is the shared carousel (`Bonfire.UI.Common.CarouselLive`), as the other dashboard widgets are."
  use Bonfire.Poll.ConnCase, async: false

  alias Bonfire.Poll.Web.WidgetPollsClosingSoonLive

  # `render_stateless/3` doesn't hand `__context__` to a Surface component, so the widget couldn't see the user
  defp render_widget(user) do
    assigns =
      WidgetPollsClosingSoonLive
      |> Surface.default_props()
      |> Map.new()
      |> Map.put(:__context__, %{current_user: user})

    Phoenix.LiveViewTest.render_component(&WidgetPollsClosingSoonLive.render/1, assigns)
  end

  test "shows open polls as cards, with arrows and a dot each" do
    user = fake_user!()
    now = DateTime.utc_now()

    for hours <- 1..2 do
      {:ok, _} =
        fake_question(
          %{
            post_content: %{name: "Closing in #{hours}h"},
            voting_dates: [
              DateTime.add(now, -60, :second),
              DateTime.add(now, hours * 3600, :second)
            ]
          },
          current_user: user,
          boundary: "public"
        )
    end

    Bonfire.Poll.Questions.closing_soon_widget(user, 3, cache: :reset)

    doc = render_widget(user) |> Floki.parse_document!()

    assert length(
             Floki.find(
               doc,
               "#polls-closing-soon-carousel [data-carousel-card] [data-role=poll_card]"
             )
           ) == 2

    assert Floki.attribute(doc, "[data-role=carousel_dots]", "data-carousel-dots") ==
             ["polls-closing-soon-carousel"]

    assert Floki.attribute(doc, "button[data-carousel-scroll]", "aria-controls") |> Enum.uniq() ==
             ["polls-closing-soon-carousel"]
  end

  defp open_poll!(user, name, opts \\ []) do
    now = DateTime.utc_now()

    {:ok, poll} =
      fake_question_with_choices(
        %{
          post_content: %{name: name},
          voting_dates: [DateTime.add(now, -60, :second), DateTime.add(now, 3600, :second)]
        },
        [%{name: "Alpha"}, %{name: "Beta"}],
        [current_user: user, boundary: "public"] ++ opts
      )

    poll
  end

  defp reset_cache(user) do
    Bonfire.Poll.Questions.closing_soon_widget(user, 3, cache: :reset)
  end

  defp card_names(doc),
    do: doc |> Floki.find("[data-role=poll_card]") |> Enum.map(&Floki.text/1)

  test "shows no results or tallies, even after someone voted" do
    author = fake_user!()
    voter = fake_user!()
    viewer = fake_user!()
    reset_cache(viewer)
    on_exit(fn -> reset_cache(nil) end)

    poll = open_poll!(author, "Poll without results")
    [choice | _] = poll.choices

    assert {:ok, _} =
             Bonfire.Poll.Votes.vote(voter, poll, [%{choice_id: choice.id, weight: 1}])

    reset_cache(viewer)

    doc = render_widget(viewer) |> Floki.parse_document!()

    assert [_] = Floki.find(doc, "[data-role=poll_card]")
    assert Floki.find(doc, "[data-role=results-toggle]") == []
    assert Floki.find(doc, "[data-role=vote-count]") == []
  end

  test "does not render a poll that has ended since it was cached" do
    author = fake_user!()
    viewer = fake_user!()
    reset_cache(viewer)
    on_exit(fn -> reset_cache(nil) end)

    ended = open_poll!(author, "Already ended poll")
    open_poll!(author, "Open poll one")
    open_poll!(author, "Open poll two")

    reset_cache(viewer)
    %{polls: polls} = Bonfire.Poll.Questions.closing_soon_widget(viewer, 3)
    # the open polls are listed too (positive first)
    assert length(polls) == 3

    now = DateTime.utc_now()

    polls =
      Enum.map(polls, fn poll ->
        if poll.id == ended.id,
          do: %{
            poll
            | voting_dates: [DateTime.add(now, -7200, :second), DateTime.add(now, -60, :second)]
          },
          else: poll
      end)

    # as if it ended while sitting in the cache
    Bonfire.Common.Cache.put(
      Bonfire.Poll.Questions.closing_soon_cache_key(viewer, 3),
      %{polls: polls}
    )

    names = render_widget(viewer) |> Floki.parse_document!() |> card_names() |> Enum.join(" ")

    assert names =~ "Open poll one"
    assert names =~ "Open poll two"
    refute names =~ "Already ended poll"
  end

  test "drops a poll I voted on, for me only" do
    author = fake_user!()
    voter = fake_user!()
    other = fake_user!()
    reset_cache(voter)
    on_exit(fn -> reset_cache(nil) end)

    poll = open_poll!(author, "Poll I vote on")
    [choice | _] = poll.choices
    reset_cache(voter)

    assert render_widget(voter) |> Floki.parse_document!() |> card_names() |> Enum.join(" ") =~
             "Poll I vote on"

    assert {:ok, _} = Bonfire.Poll.Votes.vote(voter, poll, [%{choice_id: choice.id, weight: 1}])

    refute render_widget(voter) |> Floki.parse_document!() |> card_names() |> Enum.join(" ") =~
             "Poll I vote on"

    assert render_widget(other) |> Floki.parse_document!() |> card_names() |> Enum.join(" ") =~
             "Poll I vote on"
  end

  test "the reset toast says the list updates on reload" do
    me = fake_user!()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}, current_user: me}
    }

    assert {:noreply, socket} =
             WidgetPollsClosingSoonLive.handle_event("reset_polls_closing_soon", %{}, socket)

    assert Phoenix.Flash.get(socket.assigns.flash, :info) ==
             "The list of polls will update when you reload the page, and for everyone else on their next page load."
  end
end
