defmodule Bonfire.Poll.TuningTogglesLive do
  @moduledoc """
  Layer 2 of the composer: one coherent panel of user-intent controls
  (duration, multiple-choice, behaviour toggles, and — for weighted styles —
  how much objections should weigh). Each row is a consistent
  `label + hint / control` pair. See `.claude/DESIGN.md`.
  """
  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Poll.Presets

  prop selected_preset, :atom, default: :quick

  prop tuning_state, :map,
    default: %{proposal_phase: false, hide_results: false, allow_vetoes: false}

  prop duration_hours, :integer, default: 24
  prop proposal_duration_hours, :integer, default: 24
  prop weighting, :integer, default: 1
  prop multiple_choice, :boolean, default: false

  prop event_target, :any, default: "#smart_input"

  def toggle_label(:proposal_phase), do: l("Let people suggest options")
  def toggle_label(:hide_results), do: l("Hide results until poll closes")
  def toggle_label(:allow_vetoes), do: l("Allow vetoes")
  def toggle_label(_), do: ""

  def toggle_hint(:proposal_phase), do: l("Open a proposal phase before voting.")

  def toggle_hint(:hide_results),
    do: l("Prevents people seeing early results and following the crowd.")

  def toggle_hint(:allow_vetoes), do: l("One veto can block the decision.")
  def toggle_hint(_), do: ""

  @doc "Options for the duration selectors. Single source of truth shared by both phases."
  def duration_options do
    [
      {1, l("1 hour")},
      {6, l("6 hours")},
      {24, l("1 day")},
      {72, l("3 days")},
      {168, l("1 week")}
    ]
  end

  @doc """
  Options for the objection-weight selector. User-intent vocabulary
  (no `×N` multipliers); `0` is the veto sentinel.
  """
  def objection_weight_options do
    [
      {1, l("Same as support")},
      {2, l("Twice as much")},
      {3, l("Three times as much")},
      {4, l("Four times as much")},
      {6, l("Six times as much")},
      {0, l("Block the decision (veto)")}
    ]
  end

  @doc "Whether the objection-weight row applies to this style."
  def shows_weighting?(:group_decision), do: true
  def shows_weighting?(:consensus), do: true
  def shows_weighting?(:custom), do: true
  def shows_weighting?(_), do: false

  defdelegate visible_toggles(preset_key), to: Presets
  defdelegate shows_multiple_choice?(preset_key), to: Presets
end
