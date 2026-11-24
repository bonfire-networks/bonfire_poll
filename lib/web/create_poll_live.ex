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

  # the composer's uploads, as for a post (attached to the poll, or placed in its text): kept under another name, since LiveView reserves `uploads` (see `update/2`)
  data composer_uploads, :any, default: false
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
  prop composer_policy, :map, default: nil

  # the composer container, so draft checks reach the component that owns the draft (as WritePostContentLive)
  prop event_target, :any, default: nil

  @behaviour Bonfire.UI.Common.SmartInputModule
  def smart_input_module, do: [:poll, Bonfire.Poll.Question]

  def smart_input_icon(_), do: "ph:list-checks-duotone"
  def smart_input_label(_), do: l("Poll")

  # `:merge_tuning` carries only one changed toggle; merge it into the
  # existing tuning_state so the other toggles survive.
  def update(assigns, socket) do
    {merge_tuning, assigns} = Map.pop(assigns, :merge_tuning)
    # LiveView reserves `uploads` in a component, so the composer's are kept as `composer_uploads`
    {uploads, assigns} = Map.pop(assigns, :uploads)

    socket =
      socket
      |> assign(assigns_clean(assigns))
      |> then(&if(uploads, do: assign(&1, :composer_uploads, uploads), else: &1))
      |> maybe_merge_tuning(merge_tuning)

    {:ok, socket}
  end

  defp maybe_merge_tuning(socket, nil), do: socket

  defp maybe_merge_tuning(socket, partial) when is_map(partial) do
    current = assigns(socket)[:tuning_state] || Presets.tuning_defaults(:custom)
    assign(socket, tuning_state: Map.merge(current, partial))
  end
end
