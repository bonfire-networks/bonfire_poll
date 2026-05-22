defmodule Bonfire.Poll.VotesTest do
  use Bonfire.Poll.DataCase, async: true
  import Bonfire.Me.Fake
  import Bonfire.Poll.Fake
  alias Bonfire.Poll.Votes

  describe "voting logic" do
    test "can vote and then list votes for a choice" do
      user = fake_user!()
      other_user = fake_user!()
      choices = [%{name: "A"}]

      {:ok, question} =
        fake_question_with_choices(%{voting_dates: [DateTime.utc_now()]}, choices,
          current_user: user
        )

      choice = hd(question.choices)
      # Simulate a vote
      assert {:ok, _} =
               Bonfire.Poll.Votes.vote(other_user, question, [%{choice_id: choice.id, weight: 1}])

      votes = Bonfire.Poll.Votes.list([object: choice], [])
      #  FIXME
      assert length(votes) >= 1
    end

    test "cannot vote if voting period is not open" do
      choices = [%{name: "A"}]
      # Voting window already closed.
      past_start = DateTime.utc_now() |> DateTime.add(-7200, :second)
      past_end = DateTime.utc_now() |> DateTime.add(-3600, :second)

      {:ok, question} =
        fake_question_with_choices(%{voting_dates: [past_start, past_end]}, choices)

      choice = hd(question.choices)

      assert {:error, _} =
               Bonfire.Poll.Votes.vote(fake_user!(), question, [
                 %{choice_id: choice.id, weight: 1}
               ])
    end

    test "cannot vote with multiple choices on a single choice poll" do
      choices = [%{name: "A"}, %{name: "B"}]

      {:ok, question} =
        fake_question_with_choices(
          %{voting_format: "single", voting_dates: [DateTime.utc_now()]},
          choices
        )

      choice = hd(question.choices)
      # Simulate a vote
      assert {:error, "Only one choice allowed for single-choice polls"} =
               Bonfire.Poll.Votes.vote(fake_user!(), question, [
                 %{choice_id: choice.id, weight: 1},
                 %{choice_id: List.last(question.choices).id, weight: 1}
               ])
    end

    test "can calculate total and average for weighted_multiple" do
      choices = [%{name: "A"}, %{name: "B"}]
      {:ok, question} = fake_question_with_choices(%{voting_format: "weighted_multiple"}, choices)
      # Simulate votes
      votes = [%{vote_weight: 2}, %{vote_weight: 1}]
      total = Votes.calculate_total(votes, question)
      avg = Votes.calculate_average_base_score(total, length(votes))
      assert total == 3
      assert avg == 2
    end

    test "calculate_if_visible returns nil if not visible" do
      choices = [%{name: "A"}]
      {:ok, question} = fake_question_with_choices(%{}, choices)
      choice = hd(question.choices)
      assert Votes.calculate_if_visible(choice, question, current_user: nil) == nil
    end

    test "get/3 and get!/3 fetch a user's vote on a choice" do
      choices = [%{name: "A"}]
      {:ok, question} = fake_question_with_choices(%{voting_dates: [DateTime.utc_now()]}, choices)
      choice = hd(question.choices)
      user = fake_user!()

      assert {:ok, _vote} =
               Bonfire.Poll.Votes.vote(user, question, [%{choice_id: choice.id, weight: 1}])

      # FIXME
      assert {:ok, _vote} = Votes.get(user, choice)
      assert Votes.get!(user, choice)
    end

    test "by_voter/2 lists all votes by a user" do
      choices = [%{name: "A"}, %{name: "B"}]

      {:ok, question} =
        fake_question_with_choices(
          %{voting_format: "multiple", voting_dates: [DateTime.utc_now()]},
          choices
        )

      user = fake_user!()

      assert {:ok, _} =
               Bonfire.Poll.Votes.vote(
                 user,
                 question,
                 Enum.map(question.choices, &%{choice_id: &1.id, weight: 1})
               )

      votes = Votes.by_voter(user)
      # FIXME
      assert length(votes) >= 2
    end

    test "results_visible?/3 returns true only if poll is closed or user can edit" do
      user = fake_user!()
      choices = [%{name: "A"}]

      {:ok, question} =
        fake_question_with_choices(%{voting_dates: [DateTime.utc_now()]}, choices,
          current_user: user
        )

      choice = hd(question.choices)
      # Poll open, user cannot edit
      refute Votes.results_visible?(choice, question, current_user: nil)
      # Poll closed
      ended_question = %{
        question
        | voting_dates: [nil, DateTime.add(DateTime.utc_now(), -3600, :second)]
      }

      assert Votes.results_visible?(choice, ended_question, current_user: nil)
      # User can edit 
      assert Votes.results_visible?(choice, question, current_user: user)
    end

    test "re-voting on the same choice silently keeps the original weight" do
      # Pins the current behaviour of `register_vote_choice/4` so a future
      # "edit your vote while voting is open" feature has an explicit
      # regression to update. Today, a second `vote/4` call with a different
      # weight returns success but the persisted `vote_weight` is unchanged.
      user = fake_user!()
      voter = fake_user!()
      choices = [%{name: "A"}]

      {:ok, question} =
        fake_question_with_choices(
          %{voting_dates: [DateTime.utc_now(), DateTime.add(DateTime.utc_now(), 3600, :second)]},
          choices,
          current_user: user
        )

      choice = hd(question.choices)

      assert {:ok, _} =
               Votes.vote(voter, question, [%{choice_id: choice.id, weight: -1}])

      assert {:ok, %{vote_weight: stored_weight}} = Votes.get(voter, choice)
      assert stored_weight == -1

      # Re-submit with a different weight. The function returns success but
      # the row keeps the original vote_weight.
      assert {:ok, _} =
               Votes.vote(voter, question, [%{choice_id: choice.id, weight: 2}])

      assert {:ok, %{vote_weight: stored_after_revote}} = Votes.get(voter, choice)
      assert stored_after_revote == -1
    end
  end

  describe "preview_vote_state_for_questions/2" do
    test "returns aggregate counts, vetoes, and only the current viewer's own votes" do
      author = fake_user!()
      alice = fake_user!()
      bob = fake_user!()
      carol = fake_user!()

      {:ok, question} =
        fake_question_with_choices(
          %{voting_format: "weighted_multiple", voting_dates: [DateTime.utc_now()]},
          [%{name: "A"}, %{name: "B"}],
          current_user: author
        )

      [a, b] = question.choices

      assert {:ok, _} = Votes.vote(alice, question, [%{choice_id: a.id, weight: "∞"}])
      assert {:ok, _} = Votes.vote(bob, question, [%{choice_id: b.id, weight: 2}])
      assert {:ok, _} = Votes.vote(carol, question, [%{choice_id: b.id, weight: -1}])

      states = Votes.preview_vote_state_for_questions([question], alice)
      state = states[question.id]

      assert state.counts_by_choice_id == %{a.id => 1, b.id => 2}
      assert MapSet.member?(state.vetoed_choice_ids, a.id)
      refute MapSet.member?(state.vetoed_choice_ids, b.id)
      assert state.my_vote_weights == %{a.id => nil}
    end

    test "keeps counts, vetoes, and viewer votes separated for multiple questions" do
      author = fake_user!()
      alice = fake_user!()
      bob = fake_user!()

      {:ok, first_question} =
        fake_question_with_choices(
          %{voting_format: "weighted_multiple", voting_dates: [DateTime.utc_now()]},
          [%{name: "A"}, %{name: "B"}],
          current_user: author
        )

      {:ok, second_question} =
        fake_question_with_choices(
          %{voting_format: "weighted_multiple", voting_dates: [DateTime.utc_now()]},
          [%{name: "C"}, %{name: "D"}],
          current_user: author
        )

      [a, b] = first_question.choices
      [c, d] = second_question.choices

      assert {:ok, _} = Votes.vote(alice, first_question, [%{choice_id: a.id, weight: "∞"}])
      assert {:ok, _} = Votes.vote(bob, first_question, [%{choice_id: b.id, weight: 2}])
      assert {:ok, _} = Votes.vote(alice, second_question, [%{choice_id: c.id, weight: 2}])
      assert {:ok, _} = Votes.vote(bob, second_question, [%{choice_id: d.id, weight: -1}])

      first_question_id = first_question.id
      second_question_id = second_question.id

      assert %{
               ^first_question_id => first_state,
               ^second_question_id => second_state
             } = Votes.preview_vote_state_for_questions([first_question, second_question], alice)

      assert first_state.counts_by_choice_id == %{a.id => 1, b.id => 1}
      assert first_state.my_vote_weights == %{a.id => nil}
      assert MapSet.member?(first_state.vetoed_choice_ids, a.id)
      refute Map.has_key?(first_state.counts_by_choice_id, c.id)

      assert second_state.counts_by_choice_id == %{c.id => 1, d.id => 1}
      assert second_state.my_vote_weights == %{c.id => 2}
      assert second_state.vetoed_choice_ids == MapSet.new()
      refute Map.has_key?(second_state.counts_by_choice_id, a.id)
    end

    test "returns empty state for questions with no votes" do
      {:ok, question} =
        fake_question_with_choices(%{voting_dates: [DateTime.utc_now()]}, [%{name: "A"}])

      question_id = question.id

      assert %{^question_id => state} = Votes.preview_vote_state_for_questions([question], nil)
      assert state == Votes.empty_preview_vote_state()
    end
  end
end
