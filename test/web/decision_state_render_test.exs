defmodule Bonfire.Poll.Web.DecisionStateRenderTest do
  @moduledoc """
  Integration coverage for the full assembly: builds a real poll in each
  `decision_state` and renders its thread, asserting the status band state and
  the results render — proving `view_state/4` + the `.sface` branches compose
  correctly end-to-end, not just the pure helpers in isolation.
  """
  use Bonfire.Poll.ConnCase, async: false
  import PhoenixTest
  import Bonfire.Poll.Fake

  alias Bonfire.Poll.Votes

  setup do
    account = fake_account!()
    me = fake_user!(account)
    {:ok, conn: conn(user: me, account: account), me: me}
  end

  # Open weighted_multiple poll (start in the past, end in the future = votable).
  defp open_consent(me) do
    now = DateTime.utc_now()

    {:ok, q} =
      fake_question_with_choices(
        %{
          voting_format: "weighted_multiple",
          voting_dates: [DateTime.add(now, -60), DateTime.add(now, 3600)]
        },
        [%{name: "Alpha"}, %{name: "Beta"}],
        current_user: me,
        boundary: "public"
      )

    q
  end

  # Votes can only be cast while open, so close by moving the deadline into the
  # past after the votes are in.
  defp close!(question) do
    [start | _] = question.voting_dates
    ended = DateTime.add(DateTime.utc_now(), -60, :second)

    {:ok, q} =
      Bonfire.Common.Repo.update(Ecto.Changeset.change(question, voting_dates: [start, ended]))

    q
  end

  defp react(question, choice, weight) do
    voter = fake_user!()
    assert {:ok, _} = Votes.vote(voter, question, [%{choice_id: choice.id, weight: weight}])
  end

  defp thread(conn, q), do: conn |> visit("/discussion/#{q.id}") |> wait_async()

  test ":open consent shows 'Ongoing' and the voting UI", %{conn: conn, me: me} do
    conn
    |> thread(open_consent(me))
    |> assert_has("[data-role=poll-state-label]", text: "Ongoing")
    |> assert_has("[data-role=submit-vote]")
  end

  # Group (consent) decisions impose no verdict: a closed one reads a neutral
  # "Closed" band and just the reaction results — no Agreed/Blocked/No-consensus
  # label, no outcome panel. Each group interprets the results themselves.
  test "broad agreement closes to a neutral 'Closed' band and results, no verdict",
       %{conn: conn, me: me} do
    q = open_consent(me)
    [alpha, _beta] = q.choices
    react(q, alpha, 2)
    react(q, alpha, 2)

    conn
    |> thread(close!(q))
    |> assert_has("[data-role=poll-state-label]", text: "Closed")
    |> assert_has("[data-role=choice-participation]")
    |> refute_has("[data-role=choice-carried]")
    |> refute_has("[data-role=outcome]")
  end

  test "a blocked option still shows no verdict — just 'Closed' + results",
       %{conn: conn, me: me} do
    q = open_consent(me)
    [alpha, _beta] = q.choices
    react(q, alpha, "∞")

    conn
    |> thread(close!(q))
    |> assert_has("[data-role=poll-state-label]", text: "Closed")
    |> refute_has("[data-role=choice-blocked]")
    |> refute_has("[data-role=outcome]")
  end

  test "reactions with no clear agreement close to 'Closed' + results, no verdict",
       %{conn: conn, me: me} do
    q = open_consent(me)
    [alpha, _beta] = q.choices
    react(q, alpha, 0)

    conn
    |> thread(close!(q))
    |> assert_has("[data-role=poll-state-label]", text: "Closed")
    |> refute_has("[data-role=outcome]")
  end

  test ":closed_empty when the poll closed with no votes", %{conn: conn, me: me} do
    conn
    |> thread(close!(open_consent(me)))
    |> assert_has("[data-role=outcome]", text: "Closed with no votes")
  end

  test "tally (single) closed shows the 'Top pick' caption", %{conn: conn, me: me} do
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

    [alpha, _beta] = q.choices
    react(q, alpha, 1)

    conn
    |> thread(close!(q))
    |> assert_has("[data-role=outcome]", text: "Top pick")
  end
end
