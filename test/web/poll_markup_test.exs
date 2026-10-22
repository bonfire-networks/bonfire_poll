defmodule Bonfire.Poll.Web.PollMarkupTest do
  @moduledoc """
  The poll card has one markup for every UI preset, which presets restyle only
  through `--poll-*` tokens. These tests pin the structure that styling (and
  screen readers) rely on: the state hooks on the vote form, where the meta line
  sits, Block's place relative to the reaction scale, and the reaction bar in the
  thread view.
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

  defp open_poll(me, format) do
    now = DateTime.utc_now()

    {:ok, q} =
      fake_question_with_choices(
        %{
          voting_format: format,
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

  defp react(voter, question, choice, weight),
    do: assert({:ok, _} = Votes.vote(voter, question, [%{choice_id: choice.id, weight: weight}]))

  defp thread(conn, q), do: conn |> visit("/discussion/#{q.id}") |> wait_async()

  describe "vote form state hooks" do
    # The meta line hides the kind for single-choice polls and the state while
    # open, keyed on these attributes; a missing or renamed value would show
    # both again.
    test "an open group decision carries its format and the open state", %{conn: conn, me: me} do
      conn
      |> thread(open_poll(me, "weighted_multiple"))
      |> assert_has("form[data-role=poll][data-format=weighted_multiple][data-state=open]")
    end

    test "a single-choice poll carries the single format", %{conn: conn, me: me} do
      conn
      |> thread(open_poll(me, "single"))
      |> assert_has("form[data-role=poll][data-format=single][data-state=open]")
    end

    test "a standing objection keeps an open poll's state open", %{conn: conn, me: me} do
      q = open_poll(me, "weighted_multiple")
      [alpha, _beta] = q.choices
      react(fake_user!(), q, alpha, "∞")

      conn
      |> thread(q)
      |> assert_has("form[data-role=poll][data-state=open]")
      |> assert_has("[data-role=open-block-note]")
    end

    test "a closed group decision with a block reports no consensus", %{conn: conn, me: me} do
      q = open_poll(me, "weighted_multiple")
      [alpha, _beta] = q.choices
      react(fake_user!(), q, alpha, "∞")

      conn
      |> thread(close!(q))
      |> assert_has("form[data-role=poll][data-state=no_consensus]")
    end

    test "a poll closed without votes reports closed_empty", %{conn: conn, me: me} do
      conn
      |> thread(close!(open_poll(me, "single")))
      |> assert_has("form[data-role=poll][data-state=closed_empty]")
    end
  end

  describe "meta line" do
    # Reading order should match what's on screen: options first, then the
    # line summarising them, beside the actions.
    test "renders once, after the choices", %{conn: conn, me: me} do
      conn
      |> thread(open_poll(me, "single"))
      |> assert_has("[data-role=poll-meta]", count: 1)
      |> assert_has("[data-role=choices] ~ [data-role=poll-meta]")
    end
  end

  describe "reaction scale" do
    # Block is a veto, not a step of agreement, so it sits outside the scale's
    # track; it must stay in the same radiogroup so an option still takes one
    # value and arrow keys still reach it.
    test "Block sits outside the scale but inside the option's radiogroup",
         %{conn: conn, me: me} do
      conn
      |> thread(open_poll(me, "weighted_multiple"))
      |> assert_has("[role=radiogroup] [data-block]", count: 2)
      |> refute_has("[data-role=reaction-scale] [data-block]")
      |> assert_has("[data-role=reaction-scale] [data-role=vote-score]", count: 10)
    end
  end

  describe "reaction results in the thread" do
    # The thread used to show chips; it now shares the feed's stacked bar. The
    # bar is decorative, so the count line under it carries the numbers as text
    # (visible on touch, read by screen readers), with the viewer's own marked.
    test "shows the reaction bar and a count line with the viewer's bucket marked",
         %{conn: conn, me: me} do
      q = open_poll(me, "weighted_multiple")
      [alpha, beta] = q.choices

      assert {:ok, _} =
               Votes.vote(me, q, [
                 %{choice_id: alpha.id, weight: 2},
                 %{choice_id: beta.id, weight: -1}
               ])

      conn
      |> thread(q)
      |> assert_has("[data-role=reaction-strip]", count: 2)
      |> assert_has("[data-role=reaction-strip] [data-bucket='2'][data-mine]")
      |> assert_has("[data-role=reaction-strip] [data-bucket='-1'][data-mine]")
      |> refute_has("[data-role=reaction-strip] [data-bucket='0'][data-mine]")
      |> assert_has("[data-role=reaction-counts] [data-bucket='2'][data-mine]", text: "you")
      |> assert_has("[data-role=reaction-counts] [data-bucket='-1'][data-mine]", text: "you")
      # only reactions someone gave get a count; nobody was neutral here
      |> refute_has("[data-role=reaction-counts] [data-bucket='0']")
      |> refute_has("[data-role=reaction-chips]")
    end
  end
end
