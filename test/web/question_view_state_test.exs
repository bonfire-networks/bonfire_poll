defmodule Bonfire.Poll.Web.Preview.QuestionViewStateTest do
  @moduledoc """
  DB-backed tests for `QuestionLive.view_state/4`, the function the preview
  template destructures to render a poll.

  Regression for the reported bug where the displayed total was always 0 or 1:
  counts were derived from preloaded vote edges instead of an explicit
  aggregate. A correct total must include every voter, while "your vote" state
  must stay scoped to the current viewer.
  """
  use Bonfire.Poll.DataCase, async: true
  import Bonfire.Me.Fake
  import Bonfire.Poll.Fake

  alias Bonfire.Poll.Votes
  alias Bonfire.Poll.Web.Preview.QuestionLive, as: Q

  test "total_votes and per-choice counts include all voters, and pick the winner" do
    author = fake_user!()
    voters = for _ <- 1..5, do: fake_user!()

    {:ok, question} =
      fake_question_with_choices(
        %{voting_format: "single", voting_dates: [DateTime.utc_now()]},
        [%{name: "A"}, %{name: "B"}],
        current_user: author
      )

    [a, b] = question.choices

    Enum.each(Enum.take(voters, 3), fn v ->
      assert {:ok, _} = Votes.vote(v, question, [%{choice_id: a.id, weight: 1}])
    end)

    Enum.each(Enum.drop(voters, 3), fn v ->
      assert {:ok, _} = Votes.vote(v, question, [%{choice_id: b.id, weight: 1}])
    end)

    state = Q.view_state(question)

    assert state.total_votes == 5
    assert state.counts_by_choice_id[a.id] == 3
    assert state.counts_by_choice_id[b.id] == 2
    assert state.winning_ids == [a.id]
  end

  test "a poll with no votes yields a zero total" do
    {:ok, question} =
      fake_question_with_choices(
        %{voting_format: "single", voting_dates: [DateTime.utc_now()]},
        [%{name: "A"}, %{name: "B"}]
      )

    state = Q.view_state(question)

    assert state.total_votes == 0
    assert state.winning_ids == []
  end

  test "the 'your vote' state is scoped to the viewer — Bob doesn't see Alice's vote" do
    # Regression: `object_voted` was preloaded unscoped, so once Alice voted,
    # every viewer (Bob included) saw a "Your vote" indicator. The viewer's own
    # vote must now come from preview vote state, scoped to that user.
    alice = fake_user!()
    bob = fake_user!()

    {:ok, question} =
      fake_question_with_choices(
        %{voting_format: "single", voting_dates: [DateTime.utc_now()]},
        [%{name: "A"}, %{name: "B"}],
        current_user: alice
      )

    [a, _b] = question.choices
    assert {:ok, _} = Votes.vote(alice, question, [%{choice_id: a.id, weight: 1}])

    # Alice sees her own vote.
    alice_state = Q.view_state(question, false, alice)
    assert alice_state.has_voted
    assert Map.has_key?(alice_state.my_votes, a.id)

    # Bob, who hasn't voted, sees no "Your vote".
    bob_state = Q.view_state(question, false, bob)
    refute bob_state.has_voted
    assert bob_state.my_votes == %{}

    # ...but the aggregate tally still reflects Alice's vote for everyone.
    assert bob_state.total_votes == 1
    assert bob_state.counts_by_choice_id[a.id] == 1
  end

  test "a weighted veto surfaces in vetoed_ids" do
    author = fake_user!()

    {:ok, question} =
      fake_question_with_choices(
        %{voting_format: "weighted_multiple", voting_dates: [DateTime.utc_now()]},
        [%{name: "A"}, %{name: "B"}],
        current_user: author
      )

    [a, b] = question.choices

    assert {:ok, _} = Votes.vote(fake_user!(), question, [%{choice_id: a.id, weight: "∞"}])
    assert {:ok, _} = Votes.vote(fake_user!(), question, [%{choice_id: b.id, weight: 2}])

    state = Q.view_state(question)

    assert a.id in state.vetoed_ids
    refute b.id in state.vetoed_ids
  end
end
