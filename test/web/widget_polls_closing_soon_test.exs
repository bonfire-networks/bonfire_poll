defmodule Bonfire.Poll.Web.WidgetPollsClosingSoonTest do
  @moduledoc """
  Fast, DB-less unit tests for the "Polls closing soon" widget's pure display
  helpers (kind, count noun, voted state, urgency). The `load/2` query path is
  exercised through the read-model and `voted_question_ids/2` tests in
  `polls/votes_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Bonfire.Poll.Web.WidgetPollsClosingSoonLive, as: W

  defp future(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  describe "kind/1" do
    test "names and ices consent decisions apart from tally polls" do
      assert {_consent, "ph:handshake-duotone"} = W.kind(%{voting_format: "weighted_multiple"})
      assert {_poll, "ph:chart-bar-duotone"} = W.kind(%{voting_format: "single"})
      assert {_poll, "ph:chart-bar-duotone"} = W.kind(%{voting_format: "multiple"})
      # falls back to a poll kind when the format is unset
      assert {_poll, "ph:chart-bar-duotone"} = W.kind(%{})
    end
  end

  describe "count_label/2" do
    test "counts consent reactions and tally votes in each format's own noun" do
      counts = %{"q1" => 3}
      assert W.count_label(%{id: "q1", voting_format: "weighted_multiple"}, counts) =~ "reaction"
      assert W.count_label(%{id: "q1", voting_format: "single"}, counts) =~ "vote"
    end

    test "reads zero for a poll absent from the counts map" do
      assert W.count_label(%{id: "missing", voting_format: "single"}, %{}) =~ "0"
    end
  end

  describe "voted?/2" do
    test "reports whether the viewer is in the voted set" do
      voted = MapSet.new(["q1"])
      assert W.voted?(voted, %{id: "q1"})
      refute W.voted?(voted, %{id: "q2"})
      refute W.voted?(MapSet.new(), %{id: "q1"})
    end
  end

  describe "urgency_class/1" do
    test "escalates the closing-time tone as the deadline nears" do
      assert W.urgency_class(%{voting_dates: [DateTime.utc_now(), future(30 * 60)]}) =~ "error"
      assert W.urgency_class(%{voting_dates: [DateTime.utc_now(), future(3 * 3600)]}) =~ "warning"

      assert W.urgency_class(%{voting_dates: [DateTime.utc_now(), future(3 * 86_400)]}) =~
               "base-content"
    end

    test "stays neutral (and never crashes) for closed or date-less polls" do
      assert is_binary(W.urgency_class(%{voting_dates: nil}))
      assert is_binary(W.urgency_class(%{}))
    end
  end
end
