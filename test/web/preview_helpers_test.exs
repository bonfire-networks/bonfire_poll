defmodule Bonfire.Poll.Web.Preview.HelpersTest do
  @moduledoc """
  Fast, DB-less unit tests for the pure helpers on the read-side preview
  modules. These cover the same code paths the templates exercise (vote
  detection, results gating, winner/veto identification, score look-up),
  with plain maps as fixtures so we don't pay for `Ecto.Adapters.SQL.Sandbox`
  on every assertion.
  """

  use ExUnit.Case, async: true

  alias Bonfire.Poll.Web.Preview.QuestionLive, as: Q
  alias Bonfire.Poll.Web.Preview.ChoiceLive, as: C
  alias Bonfire.Poll.Questions

  # Pure consent-histogram helpers (segments, bucketing, viewer marking) and
  # the batched read-model's 3-level histogram reducer.
  doctest Bonfire.Poll.Web.Preview.ChoiceLive, import: true
  doctest Bonfire.Poll.Votes, only: [put_nested_histogram: 5], import: true
  # Pure winning-share helper for the single/tally outcome caption.
  doctest Bonfire.Poll.Web.Preview.QuestionLive,
    only: [winning_percent: 5, decision_state: 5],
    import: true

  # ------------------------------------------------------------------
  # Fixtures
  # ------------------------------------------------------------------

  defp choice(opts \\ []) do
    %{
      id: opts[:id] || Bonfire.Common.Text.random_string(),
      post_content: opts[:post_content],
      created: opts[:created]
    }
  end

  defp future_dt(minutes_from_now) do
    DateTime.utc_now() |> DateTime.add(minutes_from_now * 60, :second)
  end

  defp past_dt(minutes_ago) do
    DateTime.utc_now() |> DateTime.add(-minutes_ago * 60, :second)
  end

  # ------------------------------------------------------------------
  # ChoiceLive helpers
  # ------------------------------------------------------------------

  describe "ChoiceLive.percent/2" do
    test "rounds to whole numbers" do
      assert C.percent(1, 3) == 33
      assert C.percent(2, 3) == 67
      assert C.percent(3, 3) == 100
    end

    test "returns 0 when total is 0 or counts are non-integers" do
      assert C.percent(0, 0) == 0
      assert C.percent(5, 0) == 0
      assert C.percent(nil, 5) == 0
      assert C.percent(2, nil) == 0
    end
  end

  describe "QuestionLive.weight_to_score/1" do
    test "maps a nil vote_weight (veto) to the ∞ sentinel" do
      assert Q.weight_to_score(nil) == "∞"
    end

    test "returns the raw integer weight unchanged" do
      for w <- [-2, -1, 0, 1, 2] do
        assert Q.weight_to_score(w) == w
      end
    end
  end

  describe "ChoiceLive.score_label/1" do
    test "looks up canonical scores from Votes.scores/0" do
      assert {-2, "Disagree", _icon, _desc} = C.score_label(-2)
      assert {0, "Neutral", _icon, _desc} = C.score_label(0)
      assert {2, "Great", _icon, _desc} = C.score_label(2)
      assert {"∞", "Block", _icon, _desc} = C.score_label("∞")
    end

    test "unknown scores resolve to nil" do
      assert C.score_label(-3) == nil
      assert C.score_label(99) == nil
      assert C.score_label(nil) == nil
    end
  end

  describe "ChoiceLive proposer helpers" do
    test "extract from preloaded Created association" do
      c =
        choice(
          created: %{creator: %{profile: %{name: "Big Wave"}, character: %{username: "wave"}}}
        )

      assert C.proposer_name(c) == "Big Wave"
      assert C.proposer_username(c) == "wave"
    end

    test "fall back to username when profile name is missing" do
      c = choice(created: %{creator: %{profile: nil, character: %{username: "wave"}}})
      assert C.proposer_name(c) == "wave"
    end

    test "return nil when the association isn't preloaded" do
      assert C.proposer_name(choice()) == nil
      assert C.proposer_username(choice()) == nil
    end
  end

  # ------------------------------------------------------------------
  # QuestionLive helpers
  # ------------------------------------------------------------------

  describe "QuestionLive.closed?/1" do
    test "true for past DateTime, false for future DateTime, false for nil" do
      assert Q.closed?(past_dt(1))
      refute Q.closed?(future_dt(60))
      refute Q.closed?(nil)
    end

    test "accepts ISO-8601 strings" do
      assert Q.closed?(DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601())
      refute Q.closed?(DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601())
    end

    test "garbage input doesn't crash" do
      refute Q.closed?("not-a-date")
      refute Q.closed?(123)
    end
  end

  describe "QuestionLive.results_locked?/2" do
    test "off by default (no hide_results field on Question yet)" do
      refute Q.results_locked?(%{}, future_dt(60))
    end

    test "honours an explicit hide_results: true when the poll is still open" do
      assert Q.results_locked?(%{hide_results: true}, future_dt(60))
    end

    test "results unhide automatically once the poll has closed" do
      refute Q.results_locked?(%{hide_results: true}, past_dt(1))
    end
  end

  describe "QuestionLive.end_time/2" do
    test "prefers explicit remote stats end_time" do
      iso = DateTime.utc_now() |> DateTime.to_iso8601()
      assert Q.end_time(%{voting_dates: [past_dt(60), future_dt(60)]}, %{end_time: iso}) == iso
    end

    test "falls back to the second element of voting_dates" do
      end_dt = future_dt(60)
      assert Q.end_time(%{voting_dates: [past_dt(60), end_dt]}, %{end_time: nil}) == end_dt
    end

    test "nil when neither source has a value" do
      assert Q.end_time(%{voting_dates: nil}, %{}) == nil
      assert Q.end_time(%{}, %{}) == nil
    end
  end

  describe "QuestionLive.winning_choice_ids/2" do
    test "single clear winner returns one id" do
      a = choice(id: "A")
      b = choice(id: "B")

      count = fn
        %{id: "A"} -> 2
        _ -> 1
      end

      assert Q.winning_choice_ids([a, b], count) == ["A"]
    end

    test "ties return every tied id" do
      a = choice(id: "A")
      b = choice(id: "B")

      assert Enum.sort(Q.winning_choice_ids([a, b], fn _ -> 2 end)) == ["A", "B"]
    end

    test "empty result when no choice received any votes" do
      assert Q.winning_choice_ids([choice(id: "A"), choice(id: "B")]) == []
    end

    test "honours a custom count function" do
      a = choice(id: "A")
      b = choice(id: "B")
      assert Q.winning_choice_ids([a, b], fn _ -> 0 end) == []

      count = fn
        %{id: "B"} -> 7
        _ -> 1
      end

      assert Q.winning_choice_ids([a, b], count) == ["B"]
    end
  end

  describe "QuestionLive.view_state/4" do
    test "uses explicit vote state for counts, vetoes, and viewer votes" do
      a = choice(id: "A")
      b = choice(id: "B")

      state =
        Q.view_state(
          %{id: "question", choices: [a, b], voting_format: "weighted_multiple"},
          false,
          nil,
          %{
            counts_by_choice_id: %{"A" => 3, "B" => 1},
            vetoed_choice_ids: MapSet.new(["B"]),
            my_vote_weights: %{"B" => nil},
            score_histogram_by_choice_id: %{
              "A" => %{2 => 2, 1 => 1},
              "B" => %{nil => 1}
            }
          }
        )

      assert state.total_votes == 4
      # consent ranks by net agreement, not raw count: A has agreement, B is blocked
      assert state.winning_ids == ["A"]
      assert state.my_votes == %{"B" => "∞"}
      assert "B" in state.vetoed_ids
    end

    test "consent winner ignores the option with the most raw reactions when it is disagreement" do
      a = choice(id: "A")
      b = choice(id: "B")

      state =
        Q.view_state(
          %{id: "question", choices: [a, b], voting_format: "weighted_multiple"},
          false,
          nil,
          %{
            counts_by_choice_id: %{"A" => 2, "B" => 5},
            vetoed_choice_ids: MapSet.new(),
            my_vote_weights: %{},
            score_histogram_by_choice_id: %{
              "A" => %{2 => 2},
              "B" => %{-2 => 4, 1 => 1}
            }
          }
        )

      assert state.winning_ids == ["A"]
    end

    test "consent winner honours the poll's veto weighting" do
      # A: one Great (+2) and one Concerned (-1). At weighting 1 the net is
      # positive (agreed); at weighting 3 the disagreement outweighs it (not).
      vote_state = %{
        counts_by_choice_id: %{"A" => 2},
        vetoed_choice_ids: MapSet.new(),
        my_vote_weights: %{},
        score_histogram_by_choice_id: %{"A" => %{2 => 1, -1 => 1}}
      }

      base = %{id: "q", choices: [choice(id: "A")], voting_format: "weighted_multiple"}

      assert Q.view_state(Map.put(base, :weighting, 1), false, nil, vote_state).winning_ids == [
               "A"
             ]

      assert Q.view_state(Map.put(base, :weighting, 3), false, nil, vote_state).winning_ids == []
    end

    test "allows local results to be toggled before voting when not locked" do
      state =
        Q.view_state(
          %{
            id: "question",
            choices: [choice(id: "A")],
            voting_dates: [DateTime.utc_now(), future_dt(60)]
          },
          false,
          nil,
          %{
            counts_by_choice_id: %{"A" => 2},
            vetoed_choice_ids: MapSet.new(),
            my_vote_weights: %{}
          }
        )

      refute state.results_visible
      assert state.results_toggleable
    end

    test "does not expose the results toggle when results are locked or already visible" do
      locked_state =
        Q.view_state(
          %{
            id: "question",
            choices: [choice(id: "A")],
            hide_results: true,
            voting_dates: [DateTime.utc_now(), future_dt(60)]
          },
          false,
          nil,
          %{
            counts_by_choice_id: %{"A" => 2},
            vetoed_choice_ids: MapSet.new(),
            my_vote_weights: %{}
          }
        )

      refute locked_state.results_visible
      refute locked_state.results_toggleable

      voted_state =
        Q.view_state(
          %{
            id: "question",
            choices: [choice(id: "A")],
            voting_dates: [DateTime.utc_now(), future_dt(60)]
          },
          false,
          nil,
          %{
            counts_by_choice_id: %{"A" => 2},
            vetoed_choice_ids: MapSet.new(),
            my_vote_weights: %{"A" => 1}
          }
        )

      assert voted_state.results_visible
      refute voted_state.results_toggleable
    end
  end

  describe "Questions.results_visible?/2" do
    test ":after_vote (default) shows results once the viewer voted, or after close" do
      assert Questions.results_visible?(%{},
               policy: :after_vote,
               ended?: false,
               viewer_voted?: true
             )

      assert Questions.results_visible?(%{},
               policy: :after_vote,
               ended?: true,
               viewer_voted?: false
             )

      refute Questions.results_visible?(%{},
               policy: :after_vote,
               ended?: false,
               viewer_voted?: false
             )
    end

    test ":after_close hides results until voting ends, even for a voter" do
      refute Questions.results_visible?(%{},
               policy: :after_close,
               ended?: false,
               viewer_voted?: true
             )

      assert Questions.results_visible?(%{}, policy: :after_close, ended?: true)
    end

    test ":always shows results regardless of vote or close state" do
      assert Questions.results_visible?(%{}, policy: :always, ended?: false, viewer_voted?: false)
    end

    test "a per-poll hide_results defers to close even under the :always policy" do
      refute Questions.results_visible?(%{hide_results: true}, policy: :always, ended?: false)
      assert Questions.results_visible?(%{hide_results: true}, policy: :always, ended?: true)
    end
  end

  describe "QuestionLive.time_remaining/1" do
    test "nil for nil input" do
      assert Q.time_remaining(nil) == nil
    end

    test "human label for past datetimes is `Closed`" do
      assert Q.time_remaining(past_dt(60)) =~ "Closed"
    end

    test "future datetimes produce a `_ minutes/hours/days left` string" do
      assert Q.time_remaining(future_dt(15)) =~ "minutes left"
      # 180 minutes → 2+ hours (clock-skew safe, well above the singular boundary)
      assert Q.time_remaining(future_dt(180)) =~ "hours left"
      # 72 hours → 3 days
      assert Q.time_remaining(future_dt(72 * 60)) =~ "days left"
    end

    test "singular form for exactly one unit" do
      # 2 minutes ahead → 1 minute left (clock skew safe, still in minute branch)
      assert Q.time_remaining(future_dt(2)) == "1 minute left"
      # 70 minutes → 1 hour left
      assert Q.time_remaining(future_dt(70)) == "1 hour left"
      # 25 hours → 1 day left
      assert Q.time_remaining(future_dt(25 * 60)) == "1 day left"
    end
  end

  describe "ChoiceLive.consent_distribution/1 (math & invariants)" do
    test "all six buckets with large counts: larger side fills 100%, both pcts in 0..100" do
      # neg = -2(7) + -1(13) = 20 ; pos = 1(40) + 2(60) = 100
      d = C.consent_distribution(%{-2 => 7, -1 => 13, 0 => 5, 1 => 40, 2 => 60, nil => 3})

      assert d.neg_count == 20
      assert d.pos_count == 100
      assert d.neutral_count == 5
      assert d.block_count == 3
      assert d.total == 128
      # pos is the larger side → fills its half; neg scaled to it: round(20*100/100)
      assert d.pos_pct == 100
      assert d.neg_pct == 20
      assert d.neg_pct in 0..100
      assert d.pos_pct in 0..100
    end

    test "side_pct rounds to the nearest integer" do
      # max_side = 3 → neg_pct = round(1*100/3) = 33
      d = C.consent_distribution(%{-1 => 1, 2 => 3})
      assert d.neg_pct == 33
      assert d.pos_pct == 100
    end

    test "no agree/disagree signal → both fills are 0%" do
      d = C.consent_distribution(%{0 => 4, nil => 2})
      assert d.neg_pct == 0
      assert d.pos_pct == 0
      assert d.neutral_count == 4
      assert d.block_count == 2
    end

    test "total always equals the sum of all buckets (incl. empty)" do
      for hist <- [
            %{},
            %{2 => 5},
            %{-2 => 1, 0 => 2, nil => 3},
            %{-2 => 7, -1 => 13, 0 => 5, 1 => 40, 2 => 60, nil => 3}
          ] do
        d = C.consent_distribution(hist)
        assert d.total == hist |> Map.values() |> Enum.sum()
      end
    end

    test "the larger non-zero side always fills 100% and pcts stay in 0..100" do
      for hist <- [%{2 => 5}, %{-2 => 1, 2 => 3}, %{-1 => 10, 1 => 10}, %{-2 => 7, 2 => 60}] do
        d = C.consent_distribution(hist)
        assert d.neg_pct in 0..100
        assert d.pos_pct in 0..100
        if max(d.neg_count, d.pos_count) > 0, do: assert(100 in [d.neg_pct, d.pos_pct])
      end
    end
  end

  describe "ChoiceLive.reaction_chips/1 ordering" do
    test "orders Disagree → Agree → Block, with the Block bucket shown as the ∞ score" do
      hist = %{2 => 1, -2 => 1, nil => 1, 0 => 1, -1 => 1, 1 => 1}
      values = C.reaction_chips(hist) |> Enum.map(fn {value, _n, _i, _c, _count} -> value end)
      assert values == [-2, -1, 0, 1, 2, "∞"]
    end
  end

  describe "QuestionLive consent winner (consent_net via winning_ids/5)" do
    test "a Block bucket does not lower an option's net agreement" do
      a = choice(id: "A")
      b = choice(id: "B")
      # identical agreement, but B also drew 5 Blocks — the Block must not change
      # B's net (a veto resolves via decision_state, not by lowering the score),
      # so both options tie on net agreement.
      histograms = %{"A" => %{2 => 3}, "B" => %{2 => 3, nil => 5}}
      winners = Q.winning_ids("weighted_multiple", [a, b], %{}, histograms, 1)
      assert Enum.sort(winners) == ["A", "B"]
    end

    test "weighting scales disagreement: an option can win at x1 but not at x3" do
      a = choice(id: "A")
      # net = 2 + (-1 * weighting): x1 → 1 (> 0, wins); x3 → -1 → floored to 0 (no winner)
      histograms = %{"A" => %{2 => 1, -1 => 1}}
      assert Q.winning_ids("weighted_multiple", [a], %{}, histograms, 1) == ["A"]
      assert Q.winning_ids("weighted_multiple", [a], %{}, histograms, 3) == []
    end
  end
end
