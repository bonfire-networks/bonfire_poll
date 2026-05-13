defmodule Bonfire.Poll.TuningTogglesLive do
  @moduledoc """
  L2 toggles for the composer. Renders only the toggles meaningful to the
  active style (see `Bonfire.Poll.Presets.visible_toggles/1`).
  """
  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Poll.Presets

  prop selected_preset, :atom, default: :quick

  prop tuning_state, :map,
    default: %{proposal_phase: false, hide_results: false, allow_vetoes: false}

  prop event_target, :any, default: "#smart_input"

  def toggle_label(:proposal_phase), do: l("Let people suggest options")
  def toggle_label(:hide_results), do: l("Hide results until poll closes")
  def toggle_label(:allow_vetoes), do: l("Allow vetoes")
  def toggle_label(_), do: ""

  def toggle_hint(:proposal_phase), do: l("Open a proposal phase before voting.")
  def toggle_hint(:hide_results), do: l("Prevents bandwagon effects.")
  def toggle_hint(:allow_vetoes), do: l("One veto can block the decision.")
  def toggle_hint(_), do: ""

  defdelegate visible_toggles(preset_key), to: Presets
end
