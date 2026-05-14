defmodule Bonfire.Poll.PollStylePickerLive do
  @moduledoc """
  Composer's L1 style picker: a horizontal card row (3 presets + Custom
  escape) sitting above the question input. Selecting a style fires
  `Bonfire.Poll:select_preset`.
  """
  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Poll.Presets

  prop selected_preset, :atom, default: :quick
  prop event_target, :any, default: "#smart_input"
end
