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

  import Bonfire.Common.Testing, only: [count_queries: 1]

  alias Bonfire.Poll.Votes
  alias Bonfire.Poll.Web.Preview.QuestionLive, as: Q

  # the view state with the tallies loaded, as after "See results"
  defp view_state_with_tallies(question, user \\ nil),
    do: Q.view_state(question, false, user, Votes.preview_vote_state_for_question(question, user))

  test "with no vote state given, view_state loads no tallies and runs no query" do
    author = fake_user!()

    {:ok, question} =
      fake_question_with_choices(
        %{voting_format: "single", voting_dates: [DateTime.utc_now()]},
        [%{name: "A"}, %{name: "B"}],
        current_user: author
      )

    assert {:ok, _} =
             Votes.vote(fake_user!(), question, [%{choice_id: hd(question.choices).id, weight: 1}])

    {state, queries} = count_queries(fn -> Q.view_state(question, false, nil) end)

    refute state.tallies_loaded
    assert state.total_votes == 0
    assert queries == 0
  end

  test "a vote state without the tallies_loaded key is read as loaded (the widget passes one)" do
    {:ok, question} =
      fake_question_with_choices(
        %{voting_format: "single", voting_dates: [DateTime.utc_now()]},
        [%{name: "A"}, %{name: "B"}],
        current_user: fake_user!()
      )

    assert Q.view_state(question, false, nil, Votes.empty_preview_vote_state()).tallies_loaded
  end

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

    state = view_state_with_tallies(question)

    assert state.total_votes == 5
    assert state.counts_by_choice_id[a.id] == 3
    assert state.counts_by_choice_id[b.id] == 2
    assert state.winning_ids == [a.id]
  end

  test "multiple: overlapping picks count per choice, voters count once, and ties share the win" do
    author = fake_user!()
    [v1, v2, v3, v4, v5] = for _ <- 1..5, do: fake_user!()

    {:ok, question} =
      fake_question_with_choices(
        %{voting_format: "multiple", voting_dates: [DateTime.utc_now()]},
        [%{name: "A"}, %{name: "B"}, %{name: "C"}],
        current_user: author
      )

    [a, b, c] = question.choices

    pick = fn voter, choices ->
      Votes.vote(voter, question, Enum.map(choices, &%{choice_id: &1.id, weight: 1}))
    end

    assert {:ok, _} = pick.(v1, [a, b])
    assert {:ok, _} = pick.(v2, [a, c])
    assert {:ok, _} = pick.(v3, [a])
    assert {:ok, _} = pick.(v4, [b, c])

    state = view_state_with_tallies(question)

    assert state.counts_by_choice_id == %{a.id => 3, b.id => 2, c.id => 2}
    assert state.total_votes == 7
    # 4 people voted, not 7: the "multiple" percent uses voters as denominator
    assert state.voter_count == 4
    assert state.winning_ids == [a.id]

    assert Q.winning_percent(
             "multiple",
             state.counts_by_choice_id,
             state.winning_ids,
             state.total_votes,
             state.voter_count
           ) ==
             75

    # A 5th voter brings B level with A: both win
    assert {:ok, _} = pick.(v5, [b])

    state = view_state_with_tallies(question)

    assert state.counts_by_choice_id == %{a.id => 3, b.id => 3, c.id => 2}
    assert state.total_votes == 8
    assert state.voter_count == 5
    assert state.winning_ids == [a.id, b.id]

    assert Q.winning_percent(
             "multiple",
             state.counts_by_choice_id,
             state.winning_ids,
             state.total_votes,
             state.voter_count
           ) ==
             60
  end

  test "weighted_multiple: the winner is the best consent net, with negatives scaled by weighting" do
    author = fake_user!()
    [p1, p2, p3, p4, p5, p6, p7] = for _ <- 1..7, do: fake_user!()

    {:ok, question} =
      fake_question_with_choices(
        %{voting_format: "weighted_multiple", weighting: 3, voting_dates: [DateTime.utc_now()]},
        [%{name: "A"}, %{name: "B"}, %{name: "C"}, %{name: "D"}],
        current_user: author
      )

    assert question.weighting == 3
    [a, b, c, d] = question.choices

    react = fn voter, reactions ->
      Votes.vote(
        voter,
        question,
        Enum.map(reactions, fn {choice, weight} -> %{choice_id: choice.id, weight: weight} end)
      )
    end

    assert {:ok, _} = react.(p1, [{a, 2}, {b, 2}])
    assert {:ok, _} = react.(p2, [{a, 2}, {b, 2}])
    assert {:ok, _} = react.(p3, [{a, 2}, {c, 1}])
    assert {:ok, _} = react.(p4, [{a, -1}, {b, 1}])
    assert {:ok, _} = react.(p5, [{b, -1}])
    assert {:ok, _} = react.(p6, [{b, -1}, {d, 0}])
    assert {:ok, _} = react.(p7, [{c, "∞"}])

    state = view_state_with_tallies(question)

    assert state.score_histogram_by_choice_id == %{
             a.id => %{2 => 3, -1 => 1},
             b.id => %{2 => 2, 1 => 1, -1 => 2},
             c.id => %{1 => 1, nil => 1},
             d.id => %{0 => 1}
           }

    assert state.counts_by_choice_id == %{a.id => 4, b.id => 5, c.id => 2, d.id => 1}
    assert state.total_votes == 12
    assert state.voter_count == 7
    assert state.vetoed_ids == [c.id]

    # Nets at weighting 3: A = 6 - 3 = 3, B = 5 - 6 = -1 (floored to 0), C = 1, D = 0.
    # B has the most reactions, and at weighting 1 it would tie A (net 3), so
    # a lone A proves the weighting was applied.
    assert state.winning_ids == [a.id]
  end

  test "a poll with no votes yields a zero total" do
    {:ok, question} =
      fake_question_with_choices(
        %{voting_format: "single", voting_dates: [DateTime.utc_now()]},
        [%{name: "A"}, %{name: "B"}]
      )

    state = view_state_with_tallies(question)

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
    alice_state = view_state_with_tallies(question, alice)
    assert alice_state.has_voted
    assert Map.has_key?(alice_state.my_votes, a.id)

    # Bob, who hasn't voted, sees no "Your vote".
    bob_state = view_state_with_tallies(question, bob)
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

    state = view_state_with_tallies(question)

    assert a.id in state.vetoed_ids
    refute b.id in state.vetoed_ids
  end
end
