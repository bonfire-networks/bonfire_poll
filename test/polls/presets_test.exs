defmodule Bonfire.Poll.PresetsTest do
  @moduledoc """
  Unit tests for `Bonfire.Poll.Presets` — the Layer 1 preset definitions
  and their translation to backend `Question` attributes.

  Pure-function tests; no DB.
  """

  use ExUnit.Case, async: true

  alias Bonfire.Poll.Presets

  describe "all/0 and default/0" do
    test "returns the three named presets in display order" do
      keys = Presets.all() |> Enum.map(& &1.key)
      assert keys == [:quick, :group_decision, :consensus]
    end

    test "default/0 is the first (Quick poll)" do
      assert Presets.default().key == :quick
    end

    test "every preset has the documented shape" do
      for preset <- Presets.all() do
        assert is_atom(preset.key)
        assert is_binary(preset.name)
        assert is_binary(preset.description)
        assert is_binary(preset.icon)
        assert preset.voting_format in ~w(single multiple weighted_multiple)
        assert is_integer(preset.weighting)
        assert is_integer(preset.duration_hours) and preset.duration_hours > 0
        assert is_map(preset.tuning_defaults)

        assert Map.keys(preset.tuning_defaults) |> Enum.sort() == [
                 :allow_vetoes,
                 :hide_results,
                 :proposal_phase
               ]
      end
    end
  end

  describe "get/1" do
    test "looks up by atom" do
      assert Presets.get(:quick).key == :quick
      assert Presets.get(:group_decision).key == :group_decision
      assert Presets.get(:consensus).key == :consensus
    end

    test "looks up by string" do
      assert Presets.get("quick").key == :quick
      assert Presets.get("group_decision").key == :group_decision
    end

    test "unknown keys fall back to :quick" do
      assert Presets.get(:nonsense).key == :quick
      assert Presets.get("nonsense").key == :quick
      assert Presets.get(nil).key == :quick
    end
  end

  describe "safe_key/1" do
    test "accepts every canonical key as string" do
      assert Presets.safe_key("quick") == :quick
      assert Presets.safe_key("group_decision") == :group_decision
      assert Presets.safe_key("consensus") == :consensus
      assert Presets.safe_key("custom") == :custom
    end

    test "accepts atoms" do
      assert Presets.safe_key(:quick) == :quick
      assert Presets.safe_key(:custom) == :custom
    end

    test "unknown input falls back to :quick" do
      assert Presets.safe_key("bogus") == :quick
      assert Presets.safe_key(nil) == :quick
      assert Presets.safe_key(42) == :quick
    end
  end

  describe "tuning_keys/0" do
    test "is the canonical list of L2 toggle keys" do
      assert Presets.tuning_keys() == [:proposal_phase, :hide_results, :allow_vetoes]
    end

    test "covers every key in every preset's tuning_defaults" do
      for preset <- Presets.all() do
        assert Map.keys(preset.tuning_defaults) |> Enum.sort() ==
                 Presets.tuning_keys() |> Enum.sort()
      end
    end
  end

  describe "tuning_defaults/1" do
    test "returns the preset's defaults for known keys" do
      assert Presets.tuning_defaults(:quick) == %{
               proposal_phase: false,
               hide_results: false,
               allow_vetoes: false
             }

      assert Presets.tuning_defaults(:group_decision) == %{
               proposal_phase: true,
               hide_results: true,
               allow_vetoes: false
             }

      assert Presets.tuning_defaults(:consensus) == %{
               proposal_phase: false,
               hide_results: false,
               allow_vetoes: true
             }
    end

    test ":custom returns all-false (no defaults to apply)" do
      assert Presets.tuning_defaults(:custom) == %{
               proposal_phase: false,
               hide_results: false,
               allow_vetoes: false
             }
    end
  end

  describe "visible_toggles/1" do
    test "does not show hide_results until it is persisted on questions" do
      refute :hide_results in Presets.visible_toggles(:group_decision)
      refute :hide_results in Presets.visible_toggles(:consensus)
      refute :hide_results in Presets.visible_toggles(:custom)
    end
  end

  describe "to_question_attrs/3" do
    test "Quick poll → single format, weighting 1, voting_dates only" do
      attrs = Presets.to_question_attrs(:quick)
      assert attrs.voting_format == "single"
      assert attrs.weighting == 1
      assert [%DateTime{}, %DateTime{}] = attrs.voting_dates
      refute Map.has_key?(attrs, :proposal_dates)
    end

    test "Group decision → weighted_multiple, weighting 3" do
      attrs = Presets.to_question_attrs(:group_decision)
      assert attrs.voting_format == "weighted_multiple"
      assert attrs.weighting == 3
    end

    test "proposal_phase=true adds proposal_dates AND shifts voting_dates" do
      attrs = Presets.to_question_attrs(:quick, %{proposal_phase: true})
      assert [%DateTime{} = p_start, %DateTime{} = p_end] = attrs.proposal_dates
      assert [%DateTime{} = v_start, %DateTime{} = v_end] = attrs.voting_dates
      # voting starts when proposal ends
      assert DateTime.compare(v_start, p_end) == :eq
      assert DateTime.compare(p_start, p_end) == :lt
      assert DateTime.compare(v_start, v_end) == :lt
    end

    test "allow_vetoes=true forces weighted_multiple regardless of preset" do
      attrs = Presets.to_question_attrs(:quick, %{allow_vetoes: true})
      assert attrs.voting_format == "weighted_multiple"
    end

    test "allow_vetoes=true zeros out weighting (∞ sentinel)" do
      attrs = Presets.to_question_attrs(:group_decision, %{allow_vetoes: true})
      assert attrs.weighting == 0
    end

    test "duration_hours overrides the preset default" do
      now = DateTime.utc_now()
      attrs = Presets.to_question_attrs(:quick, %{}, duration_hours: 1)
      [start, end_dt] = attrs.voting_dates
      span_seconds = DateTime.diff(end_dt, start)
      # 1 hour ± rounding tolerance for the test
      assert_in_delta span_seconds, 3600, 5
      # And the start is approximately now
      assert_in_delta DateTime.diff(start, now), 0, 5
    end

    test "unknown preset key uses :quick's config" do
      attrs = Presets.to_question_attrs(:bogus)
      quick = Presets.get(:quick)
      assert attrs.voting_format == quick.voting_format
      assert attrs.weighting == quick.weighting
    end

    test "proposal_duration_hours sizes the proposal window independently of voting" do
      attrs =
        Presets.to_question_attrs(
          :group_decision,
          %{proposal_phase: true},
          duration_hours: 48,
          proposal_duration_hours: 6
        )

      [p_start, p_end] = attrs.proposal_dates
      [v_start, v_end] = attrs.voting_dates

      assert_in_delta DateTime.diff(p_end, p_start), 6 * 3600, 5
      assert_in_delta DateTime.diff(v_end, v_start), 48 * 3600, 5
      # Voting starts exactly when proposal ends.
      assert DateTime.compare(v_start, p_end) == :eq
    end

    test "proposal_duration_hours defaults to Presets.default_proposal_hours/0" do
      attrs = Presets.to_question_attrs(:quick, %{proposal_phase: true}, duration_hours: 24)
      [p_start, p_end] = attrs.proposal_dates

      assert_in_delta DateTime.diff(p_end, p_start),
                      Presets.default_proposal_hours() * 3600,
                      5
    end

    test "proposal_duration_hours is ignored when proposal_phase is off" do
      attrs =
        Presets.to_question_attrs(:quick, %{proposal_phase: false},
          duration_hours: 24,
          proposal_duration_hours: 168
        )

      refute Map.has_key?(attrs, :proposal_dates)
    end
  end
end
