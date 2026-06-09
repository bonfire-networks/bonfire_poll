defmodule Bonfire.Poll.Web.VoteSubmitRefreshTest do
  @moduledoc """
  Guards that casting a vote through the live form *updates the UI in place* —
  not just the DB. `QuestionLive` is a stateless component that re-queries vote
  state only when re-rendered, so the `submit_vote` handler must actually trigger
  that re-render (the voting form should give way to the results/voted view under
  the default `:after_vote` policy). If it doesn't, the voter sees a thank-you
  flash but the form stays, looking like nothing happened.
  """
  use Bonfire.Poll.ConnCase, async: false
  import PhoenixTest
  import Bonfire.Poll.Fake

  setup do
    account = fake_account!()
    me = fake_user!(account)
    {:ok, conn: conn(user: me, account: account), me: me}
  end

  defp open_single(me) do
    now = DateTime.utc_now()

    {:ok, q} =
      fake_question_with_choices(
        %{
          voting_format: "single",
          voting_dates: [DateTime.add(now, -60), DateTime.add(now, 3600)]
        },
        [%{name: "Alpha"}, %{name: "Beta"}],
        current_user: me,
        boundary: "public"
      )

    q
  end

  test "casting a vote replaces the voting form with the results view", %{conn: conn, me: me} do
    q = open_single(me)

    conn
    |> visit("/discussion/#{q.id}")
    |> wait_async()
    |> assert_has("[data-role=submit-vote]")
    |> choose("Alpha")
    |> click_button("[data-role=submit-vote]", "Vote")
    |> wait_async()
    # Under :after_vote, voting becomes "voted?" → results_visible → the submit
    # control is gone. If the component didn't re-query, the form would persist.
    |> refute_has("[data-role=submit-vote]")
  end
end
