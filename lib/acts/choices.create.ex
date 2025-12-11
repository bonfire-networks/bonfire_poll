defmodule Bonfire.Poll.Acts.Choices.Create do
  @moduledoc """
  Add choice(s) to a question

  Epic Options:
    * `:current_user` - user that will create the choice, required.
    * `:choice_attrs` (configurable) - attrs to create the choice from, required.
    * `:choice_id` (configurable) - id to use for the created choice (handy for creating
      activitypub objects with an id representing their reported creation time)

  Act Options:
    * `:id` - epic options key to find an id to force override with at, default: `:choice_id`
    * `:as` - key to assign changeset to, default: `:choice`.
    * `:attrs` - epic options key to find the attributes at, default: `:choice_attrs`.
  """

  alias Bonfire.Epics.Epic
  alias Bonfire.Poll.Choices
  use Arrows
  import Bonfire.Epics
  alias Bonfire.Common.Errors
  use Bonfire.Common.Repo

  @doc false
  def run(epic, act) do
    current_user = Bonfire.Common.Utils.current_user(epic.assigns[:options])

    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic

      not (is_struct(current_user) or is_binary(current_user)) ->
        maybe_debug(epic, act, current_user, "Skipping due to missing current_user")
        epic

      true ->
        options = epic.assigns[:options]

        # as = Keyword.get(act.options, :as) || Keyword.get(act.options, :on, :question)
        on = Keyword.get(act.options, :on, :question)

        attrs_key = Keyword.get(act.options, :attrs, :question_attrs)

        attrs =
          Keyword.get(epic.assigns[:options], attrs_key, %{})
          |> debug("choice attrs in act")

        # Actually create and link choices
        with %{} = question <- epic.assigns[on] || {:error, "No question found to add choices to"},
             choices = attrs[:choices] || [],
             {:ok, _} <- Choices.simple_create_and_put(nil, choices, question, options) do
          question
          |> repo().maybe_preload(choices: [:post_content])
          |> Epic.assign(epic, on, ...)
        else
          e ->
            Epic.add_error(
              epic,
              act,
              "Could not create choices for question: #{Errors.error_msg(e)}"
            )
        end
    end
  end
end
