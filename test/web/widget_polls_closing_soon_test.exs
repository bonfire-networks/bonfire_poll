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
            voting_dates: [DateTime.add(now, -60, :second), DateTime.add(now, hours * 3600, :second)]
          },
          current_user: user,
          boundary: "public"
        )
    end

    Bonfire.Poll.Questions.closing_soon_widget(user, 3, cache: :reset)

    doc = render_widget(user) |> Floki.parse_document!()

    assert length(Floki.find(doc, "#polls-closing-soon-carousel [data-carousel-card] [data-role=poll_card]")) == 2

    assert Floki.attribute(doc, "[data-role=carousel_dots]", "data-carousel-dots") ==
             ["polls-closing-soon-carousel"]

    assert Floki.attribute(doc, "button[data-carousel-scroll]", "aria-controls") |> Enum.uniq() ==
             ["polls-closing-soon-carousel"]
  end
end
