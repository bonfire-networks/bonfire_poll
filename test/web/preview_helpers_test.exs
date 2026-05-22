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
            my_vote_weights: %{"B" => nil}
          }
        )

      assert state.total_votes == 4
      assert state.winning_ids == ["A"]
      assert state.my_votes == %{"B" => "∞"}
      assert "B" in state.vetoed_ids
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
          %{counts_by_choice_id: %{"A" => 2}, vetoed_choice_ids: MapSet.new(), my_vote_weights: %{}}
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
          %{counts_by_choice_id: %{"A" => 2}, vetoed_choice_ids: MapSet.new(), my_vote_weights: %{}}
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
end
