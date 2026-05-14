defmodule Bonfire.Poll.Acts.PresetAttrs do
  @moduledoc """
  Epic act: resolve `:preset_params` (composer L1/L2 choices) into Question
  attrs and merge them into `:question_attrs`. Form attrs win over presets,
  so L3 (Advanced) overrides take precedence. No-op when `:preset_params`
  is absent or empty.
  """

  alias Bonfire.Epics.Epic
  alias Bonfire.Poll.Presets

  def run(epic, _act) do
    case epic.assigns[:options][:preset_params] do
      %{} = preset_params when map_size(preset_params) > 0 ->
        preset_attrs =
          Presets.to_question_attrs(
            Presets.safe_key(preset_params[:preset]),
            preset_params[:tuning] || %{},
            duration_hours: preset_params[:duration_hours],
            proposal_duration_hours: preset_params[:proposal_duration_hours],
            multiple_choice: preset_params[:multiple_choice] == true
          )

        new_options =
          Keyword.update(
            epic.assigns[:options],
            :question_attrs,
            preset_attrs,
            fn form_attrs -> Map.merge(preset_attrs, form_attrs) end
          )

        Epic.assign(epic, :options, new_options)

      _ ->
        epic
    end
  end
end
