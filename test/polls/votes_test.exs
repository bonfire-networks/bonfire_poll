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
end
