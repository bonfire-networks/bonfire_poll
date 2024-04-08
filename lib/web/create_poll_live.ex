defmodule Bonfire.Poll.Web.CreatePollLive do
  use Bonfire.UI.Common.Web, :stateful_component
  use Bonfire.Common.Utils
  # alias Surface.Components.Form.TextArea
  alias Surface.Components.Form
  # alias Surface.Components.Form.HiddenInput
  alias Surface.Components.Form.TextInput
  alias Surface.Components.Form.Field
  alias Surface.Components.Form.Inputs
  alias Bonfire.UI.Common.WriteEditorLive
  alias Bonfire.Poll.{Questions, Question}
  alias Bonfire.Poll.{WeightSelector, PhaseSelector}

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
  # prop uploads, :any, default: nil
  prop uploaded_files, :list, default: nil
  prop title_prompt, :string, default: nil
  prop thread_mode, :any, default: nil

  prop open_boundaries, :boolean, default: false
  prop boundaries_modal_id, :string, default: :sidebar_composer

  # Classes to customize the smart input appearance
  prop textarea_container_class, :css_class
  prop textarea_container_class_alpine, :string
  prop textarea_class, :css_class

  @behaviour Bonfire.UI.Common.SmartInputModule
  def smart_input_module, do: [:poll, Bonfire.Poll.Question]

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(Map.drop(assigns, [:uploads]) |> assigns_clean())}
  end
end
