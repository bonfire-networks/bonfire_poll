defmodule Bonfire.Poll.LiveHandlerTest do
  @moduledoc """
  Pure-function unit tests for `Bonfire.Poll.LiveHandler`. Covers shape
  parsing that's otherwise only reachable through the LiveView socket
  dispatch — making the per-shape behaviour locked-in without ceremony.
  """

  use ExUnit.Case, async: true

  alias Bonfire.Poll.LiveHandler

  describe "parse_votes/1" do
    test "weighted_multiple indexed-map shape" do
      # The shape `voting_live.sface` actually submits: each choice carries
      # both `choice_id` (hidden) and `weight` (Alpine-mirrored hidden) under
      # an index-keyed `votes` namespace.
      params = %{
        "votes" => %{
          "0" => %{"choice_id" => "CHOICE_A", "weight" => "-1"},
          "1" => %{"choice_id" => "CHOICE_B", "weight" => "2"}
        }
      }

      result = LiveHandler.parse_votes(params)

      # Map iteration order isn't guaranteed; assert by content, not index.
      assert Enum.sort_by(result, & &1.choice_id) == [
               %{choice_id: "CHOICE_A", weight: "-1"},
               %{choice_id: "CHOICE_B", weight: "2"}
             ]
    end

    test "weighted_multiple entry with no weight falls back to 1" do
      params = %{
        "votes" => %{
          "0" => %{"choice_id" => "CHOICE_A"}
        }
      }

      assert LiveHandler.parse_votes(params) == [%{choice_id: "CHOICE_A", weight: 1}]
    end

    test "weighted_multiple entry with a blank weight falls back to 1" do
      # An empty hidden input is truthy in Elixir, so `|| 1` wouldn't catch it.
      params = %{"votes" => %{"0" => %{"choice_id" => "CHOICE_A", "weight" => ""}}}

      assert LiveHandler.parse_votes(params) == [%{choice_id: "CHOICE_A", weight: 1}]
    end

    test "single-choice form shape (`vote` is a string)" do
      params = %{"vote" => "CHOICE_A"}
      assert LiveHandler.parse_votes(params) == [%{choice_id: "CHOICE_A", weight: 1}]
    end

    test "multiple-choice form shape (`vote` is a map of choice_id => weight)" do
      params = %{"vote" => %{"CHOICE_A" => "1", "CHOICE_B" => "1"}}

      assert Enum.sort_by(LiveHandler.parse_votes(params), & &1.choice_id) == [
               %{choice_id: "CHOICE_A", weight: "1"},
               %{choice_id: "CHOICE_B", weight: "1"}
             ]
    end

    test "unknown shape returns an empty list, not a crash" do
      assert LiveHandler.parse_votes(%{}) == []
      assert LiveHandler.parse_votes(%{"question_id" => "Q"}) == []
    end
  end
end
