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

      votes = Bonfire.Poll.Votes.list([objects: choice], [])
      assert length(votes) == 1
    end

    test "counts and listings are scoped per choice/voter, not instance-global" do
      # regression: `count`/`for_choice`/`by_voter` passed SINGULAR `:object`/`:subject` filter
      # keys, which `Edges.query_parent` doesn't recognise → they silently returned ALL vote
      # edges on the instance. Needs 2 polls + 2 voters in one test so scoped ≠ global.
      owner1 = fake_user!()
      owner2 = fake_user!()
      voter1 = fake_user!()
      voter2 = fake_user!()

      {:ok, poll1} =
        fake_question_with_choices(
          %{voting_format: "multiple", voting_dates: [DateTime.utc_now()]},
          [%{name: "A"}, %{name: "B"}],
          current_user: owner1
        )

      {:ok, poll2} =
        fake_question_with_choices(
          %{voting_format: "multiple", voting_dates: [DateTime.utc_now()]},
          [%{name: "C"}, %{name: "D"}],
          current_user: owner2
        )

      [a, b] = poll1.choices
      [c, d] = poll2.choices

      assert {:ok, _} = Votes.vote(voter1, poll1, [%{choice_id: a.id, weight: 1}])

      assert {:ok, _} =
               Votes.vote(voter2, poll1, [
                 %{choice_id: a.id, weight: 1},
                 %{choice_id: b.id, weight: 1}
               ])

      assert {:ok, _} = Votes.vote(voter1, poll2, [%{choice_id: c.id, weight: 1}])

      # per-choice counts (the poll's owner can always see results)
      assert Votes.calculate_if_visible(a, poll1, current_user: owner1) == 2
      assert Votes.calculate_if_visible(b, poll1, current_user: owner1) == 1
      assert Votes.calculate_if_visible(c, poll2, current_user: owner2) == 1
      assert Votes.calculate_if_visible(d, poll2, current_user: owner2) == 0

      # per-choice listings
      assert length(Votes.for_choice(a)) == 2
      assert length(Votes.for_choice(b)) == 1
      assert Votes.for_choice(d) == []

      # per-voter listings: each vote/4 call also records one question-level Vote edge
      # (the activity), so voter1 = 2 choice votes + 2 question votes across the two polls
      assert length(Votes.by_voter(voter1)) == 4
      # voter2 = 2 choice votes + 1 question vote
      assert length(Votes.by_voter(voter2)) == 3
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
      # 2 choice votes + 1 question-level Vote edge (the activity)
      assert length(votes) == 3
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

    test "results_visible?/3 shows results to a non-owner voter on an open :after_vote poll (UI/API parity)" do
      owner = fake_user!()
      voter = fake_user!()
      non_voter = fake_user!()
      choices = [%{name: "A"}]

      {:ok, question} =
        fake_question_with_choices(%{voting_dates: [DateTime.utc_now()]}, choices,
          current_user: owner
        )

      choice = hd(question.choices)

      assert {:ok, _} = Votes.vote(voter, question, [%{choice_id: choice.id, weight: 1}])

      # Default :after_vote policy: a non-owner who has voted sees results while
      # the poll is still open — the lazy `viewer_voted?` lookup makes the API
      # path match the UI preview.
      assert Votes.results_visible?(choice, question, current_user: voter)
      # A logged-in non-voter does not, until the poll closes.
      refute Votes.results_visible?(choice, question, current_user: non_voter)
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

  describe "notification routing" do
    test "voting on your own poll does not notify yourself" do
      author = fake_user!()

      {:ok, question} =
        fake_question_with_choices(
          %{voting_dates: [DateTime.utc_now()]},
          [%{name: "A"}],
          current_user: author
        )

      [choice] = question.choices

      assert {:ok, _} =
               Votes.vote(author, question, [%{choice_id: choice.id, weight: 1}])

      refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, question,
               current_user: author
             )
    end

    test "voting on someone else's poll notifies the poll creator" do
      author = fake_user!()
      voter = fake_user!()

      {:ok, question} =
        fake_question_with_choices(
          %{voting_dates: [DateTime.utc_now()]},
          [%{name: "A"}],
          current_user: author
        )

      [choice] = question.choices

      assert {:ok, _} =
               Votes.vote(voter, question, [%{choice_id: choice.id, weight: 1}])

      assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, question,
               current_user: author
             )

      refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, question,
               current_user: voter
             )
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

      # Per-choice vote-weight histogram: the nil bucket is the block/veto, and
      # `counts_by_choice_id` / `vetoed_choice_ids` above are derived from it.
      assert state.score_histogram_by_choice_id == %{
               a.id => %{nil => 1},
               b.id => %{2 => 1, -1 => 1}
             }

      # Distinct voters across all choices (alice, bob, carol) — not the sum of
      # per-choice counts, which would double-count multi-select voters.
      assert state.voter_count == 3
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

    test "histogram, counts, vetoes and voter_count are exact across all six buckets at scale" do
      author = fake_user!()

      {:ok, question} =
        fake_question_with_choices(
          %{voting_format: "weighted_multiple", voting_dates: [DateTime.utc_now()]},
          [%{name: "A"}, %{name: "B"}],
          current_user: author
        )

      [a, b] = question.choices

      # Spread distinct voters across every bucket on choice A. `"∞"` is the Block
      # weight (stored as vote_weight nil). Each reaction needs its own voter
      # (one vote per voter per choice), so this also exercises the SQL GROUP BY
      # and count(:distinct) on real, non-trivial data.
      react_on_a = fn weight, n ->
        for _ <- 1..n do
          voter = fake_user!()
          assert {:ok, _} = Votes.vote(voter, question, [%{choice_id: a.id, weight: weight}])
          voter
        end
      end

      react_on_a.("∞", 1)
      react_on_a.(-2, 3)
      react_on_a.(-1, 3)
      react_on_a.(0, 2)
      react_on_a.(1, 5)
      great_on_a = react_on_a.(2, 10)

      # 4 of A's "Great" reactors ALSO react to B — they are not new people, so
      # voter_count (distinct) must stay 24, NOT 28 (the sum of per-choice counts).
      for voter <- Enum.take(great_on_a, 4) do
        assert {:ok, _} = Votes.vote(voter, question, [%{choice_id: b.id, weight: 2}])
      end

      state = Votes.preview_vote_state_for_questions([question], nil)[question.id]

      # Exact per-bucket histogram, including the nil/Block bucket.
      assert state.score_histogram_by_choice_id[a.id] ==
               %{nil => 1, -2 => 3, -1 => 3, 0 => 2, 1 => 5, 2 => 10}

      assert state.score_histogram_by_choice_id[b.id] == %{2 => 4}

      # counts are the in-memory sum of the histogram buckets (24 on A, 4 on B).
      assert state.counts_by_choice_id == %{a.id => 24, b.id => 4}

      # the nil/Block bucket on A surfaces as a veto; B has none.
      assert MapSet.member?(state.vetoed_choice_ids, a.id)
      refute MapSet.member?(state.vetoed_choice_ids, b.id)

      # 24 distinct people voted; the sum of per-choice counts (28) would overcount.
      assert state.voter_count == 24
    end
  end

  describe "voted_question_ids/2" do
    test "returns only the questions the voter has actually voted on" do
      author = fake_user!()
      alice = fake_user!()
      bob = fake_user!()

      {:ok, q1} =
        fake_question_with_choices(%{voting_dates: [DateTime.utc_now()]}, [%{name: "A"}],
          current_user: author
        )

      {:ok, q2} =
        fake_question_with_choices(%{voting_dates: [DateTime.utc_now()]}, [%{name: "B"}],
          current_user: author
        )

      [a] = q1.choices
      assert {:ok, _} = Votes.vote(alice, q1, [%{choice_id: a.id, weight: 1}])

      voted = Votes.voted_question_ids(alice, [q1.id, q2.id])
      assert MapSet.member?(voted, q1.id)
      refute MapSet.member?(voted, q2.id)

      # A voter with no votes, a nil voter, and an empty id list all yield the empty set.
      assert Votes.voted_question_ids(bob, [q1.id, q2.id]) == MapSet.new()
      assert Votes.voted_question_ids(nil, [q1.id]) == MapSet.new()
      assert Votes.voted_question_ids(alice, []) == MapSet.new()
    end
  end

  describe "read-model query count (performance guard)" do
    setup do
      author = fake_user!()
      viewer = fake_user!()
      voter = fake_user!()

      questions =
        for _ <- 1..5 do
          {:ok, q} =
            fake_question_with_choices(
              %{voting_format: "weighted_multiple", voting_dates: [DateTime.utc_now()]},
              [%{name: "A"}, %{name: "B"}],
              current_user: author
            )

          [a, _b] = q.choices
          assert {:ok, _} = Votes.vote(voter, q, [%{choice_id: a.id, weight: 2}])
          q
        end

      [first | _] = questions
      [a, _b] = first.choices
      assert {:ok, _} = Votes.vote(viewer, first, [%{choice_id: a.id, weight: 1}])

      {:ok, questions: questions, viewer: viewer, first: first}
    end

    test "one poll + logged-in viewer = exactly 3 queries (histogram, voter-count, viewer-votes)",
         %{first: q, viewer: viewer} do
      assert count_queries(fn -> Votes.preview_vote_state_for_question(q, viewer) end) == 3
    end

    test "one poll + no viewer = 2 queries (the per-viewer query is skipped)", %{first: q} do
      assert count_queries(fn -> Votes.preview_vote_state_for_question(q, nil) end) == 2
    end

    test "the batch API is constant: all N polls in one call = 3 queries",
         %{questions: questions, viewer: viewer} do
      assert count_queries(fn -> Votes.preview_vote_state_for_questions(questions, viewer) end) ==
               3
    end

    test "per-poll loading (what the stateless component does today) is linear: N polls = 3*N queries",
         %{questions: questions, viewer: viewer} do
      n = length(questions)

      assert count_queries(fn ->
               Enum.each(questions, &Votes.preview_vote_state_for_question(&1, viewer))
             end) == 3 * n
    end
  end

  # Count DB queries issued while running `fun` once. Ecto derives the telemetry
  # prefix from the repo module: Bonfire.Common.Repo -> [:bonfire, :common, :repo].
  defp count_queries(fun) do
    counter = :counters.new(1, [])
    handler_id = {__MODULE__, :query_count, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:bonfire, :common, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == test_pid, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(counter, 1)
  end
end
