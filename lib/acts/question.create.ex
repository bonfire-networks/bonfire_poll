defmodule Bonfire.Poll.Question.Create do
  @moduledoc """
  Builds the initial `Bonfire.Poll.Question` changeset for the poll-creation
  epic and registers it for insertion via `Bonfire.Ecto.Acts.Work`.

  Epic Options:
    * `:current_user` — user that will create the question, required.
    * `:question_attrs` (configurable) — attrs to create the question from,
      required.

  Act Options:
    * `:as` — key to assign the changeset to, default: `:question`.
    * `:attrs` — epic options key to find the attributes at,
      default: `:question_attrs`.
  """

  alias Bonfire.Ecto.Acts.Work
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic
  alias Bonfire.Poll.Questions

  alias Ecto.Changeset
  use Arrows
  import Bonfire.Epics
  # import Untangle

  # see module documentation
  @doc false
  def run(epic, act) do
    current_user = Bonfire.Common.Utils.current_user_or_id(epic.assigns[:options])

    cond do
      epic.errors != [] ->
        maybe_debug(
          epic,
          act,
          length(epic.errors),
          "Skipping due to epic errors"
        )

        epic

      not (is_struct(current_user) or is_binary(current_user)) ->
        maybe_debug(
          epic,
          act,
          current_user,
          "Skipping due to missing current_user"
        )

        epic

      true ->
        as = Keyword.get(act.options, :as) || Keyword.get(act.options, :on, :question)
        attrs_key = Keyword.get(act.options, :attrs, :question_attrs)

        # id_key = Keyword.get(act.options, :id, :question_id)
        # id = epic.assigns[:options][id_key]

        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        # _boundary = epic.assigns[:options][:boundary]

        maybe_debug(
          epic,
          act,
          attrs_key,
          "Assigning changeset to :#{as} using attrs"
        )

        # maybe_debug(epic, act, attrs, "Post attrs")
        if attrs == %{}, do: maybe_debug(act, attrs, "empty attrs")

        Questions.base_changeset(attrs)
        |> Map.put(:action, :insert)
        # |> maybe_overwrite_id(id)
        |> Epic.assign(epic, as, ...)
        |> Work.add(:question)
    end
  end

  # defp maybe_overwrite_id(changeset, nil), do: changeset

  # defp maybe_overwrite_id(changeset, id),
  #   do: Changeset.put_change(changeset, :id, id)
end
