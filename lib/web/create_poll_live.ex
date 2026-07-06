defmodule Bonfire.Poll.Web.CreatePollLive do
  use Bonfire.UI.Common.Web, :stateful_component
  use Bonfire.Common.Utils
  alias Surface.Components.Form
  alias Surface.Components.Form.TextInput
  alias Surface.Components.Form.Field
  alias Surface.Components.Form.Inputs
  alias Bonfire.Poll.Presets

  prop proposals, :list, default: []

  prop context_id, :string, default: nil
  prop create_object_type, :any, default: nil
  prop to_boundaries, :any, default: nil
  prop to_circles, :list, default: []
  prop exclude_circles, :list, default: []
  prop smart_input_opts, :map, default: %{}
  prop showing_within, :atom, default: nil
  prop insert_text, :string, default: nil
  prop preloaded_recipients, :any, default: nil
  prop uploaded_files, :list, default: nil
  prop title_prompt, :string, default: nil
  prop thread_mode, :any, default: nil

  prop open_boundaries, :boolean, default: false
  prop boundaries_modal_id, :string, default: :sidebar_composer

  # `data`, not `prop`: Surface re-applies prop defaults on every parent
  # re-render, which would silently reset the composer's local state on
  # unrelated diffs. Mutated only via `update/2` (incl. `send_update` from
  # `Bonfire.Poll.LiveHandler`). See `.claude/DESIGN.md`.
  data selected_preset, :atom, default: :quick

  data tuning_state, :map,
    default: %{proposal_phase: false, hide_results: false, allow_vetoes: false}

  data duration_hours, :integer, default: 24
  # Mirrors the active preset's weighting so the form's submitted value
  # doesn't silently override the preset via PresetAttrs's form-wins merge.
  data weighting, :integer, default: 1
  data proposal_duration_hours, :integer, default: 24
  data visible_option_count, :integer, default: 2
  data multiple_choice, :boolean, default: false

  prop textarea_container_class, :css_class
  prop textarea_container_class_alpine, :string
  prop textarea_class, :css_class

  @behaviour Bonfire.UI.Common.SmartInputModule
  def smart_input_module, do: [:poll, Bonfire.Poll.Question]

  def smart_input_icon(_), do: "ph:list-checks-duotone"
  def smart_input_label(_), do: l("Poll")

  # `:merge_tuning` carries only one changed toggle; merge it into the
  # existing tuning_state so the other toggles survive.
  def update(assigns, socket) do
    {merge_tuning, assigns} = Map.pop(assigns, :merge_tuning)

    socket =
      socket
      |> assign(
        Map.drop(assigns, [:uploads])
        |> assigns_clean()
        |> preserve_composer_status(socket)
      )
      |> maybe_merge_tuning(merge_tuning)

    {:ok, socket}
  end

  # `input_status` (the submit-button state) is set by validate on THIS component,
  # while parent re-renders re-send their own stale `smart_input_opts` copy as a
  # prop. Only maps that explicitly carry `:input_status` (validate results,
  # composer resets) apply as-is — others inherit the current opts' missing keys,
  # so poll controls (duration, add-option, toggles) can't disable a live draft.
  defp preserve_composer_status(assigns, socket) do
    current = assigns(socket)[:smart_input_opts]

    Enum.map(assigns, fn
      {:smart_input_opts, incoming} = entry when is_map(incoming) ->
        if is_map(current) and not Map.has_key?(incoming, :input_status) do
          {:smart_input_opts, Map.merge(current, incoming)}
        else
          entry
        end

      other ->
        other
    end)
  end

  defp maybe_merge_tuning(socket, nil), do: socket

  defp maybe_merge_tuning(socket, partial) when is_map(partial) do
    current = assigns(socket)[:tuning_state] || Presets.tuning_defaults(:custom)
    assign(socket, tuning_state: Map.merge(current, partial))
  end
end
