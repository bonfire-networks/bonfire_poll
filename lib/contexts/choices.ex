defmodule Bonfire.Poll.Choices do
  use Bonfire.Common.Utils
  import Bonfire.Poll
  alias Bonfire.Poll.Question
  alias Bonfire.Poll.Choice
  alias Bonfire.Epics.Epic

  # TODO?
  # def upsert(options \\ []) do
  #   with {:ok, %{id: id} = published} <-
  #          Bonfire.Pages.run_epic(
  #            :upsert,
  #            options ++ [do_not_strip_html: true],
  #            __MODULE__,
  #            :choice
  #          ) do
  #     if options[:question_id],
  #       do:
  #         put_choice(id, options[:question_id])
  #         |> debug("put_in_page - TODO: move to epic?")

  #     {:ok, published}
  #   end
  # end

  def simple_create_and_put(index \\ nil, choices_or_choice_attrs, question_id, opts)

  def simple_create_and_put(index, choices, question_id, opts) when is_list(choices) do
    initial_index = index || 0

    choices
    |> Enum.with_index()
    |> Enum.map(fn {choice, i} ->
      do_simple_create_and_put(i + initial_index, choice, question_id, opts)
    end)
    |> all_oks_or_error()
  end

  def simple_create_and_put(index, %{} = choices, question_id, opts) do
    if Enums.string_keys?(choices) do
      initial_index = index || 0

      choices
      |> Enum.with_index()
      |> Enum.map(fn {{i, choice}, fallback_i} ->
        do_simple_create_and_put(
          (Types.maybe_to_integer(i) || fallback_i) + initial_index,
          choice,
          question_id,
          opts
        )
      end)
      |> all_oks_or_error()
    else
      simple_create_and_put(index, [choices], question_id, opts)
    end
  end

  defp do_simple_create_and_put(index, attrs, question_id, opts) do
    with cs <-
           Bonfire.Social.PostContents.cast(
             %Choice{},
             attrs,
             current_user(opts),
             opts[:boundary] || "public",
             opts
           ),
         {:ok, %{id: choice_id} = choice} <- repo().insert(cs),
         {:ok, _} <- put_choice(choice_id, question_id, index) do
      {:ok, choice}
    end
  end

  def put_choice(choice, question, position \\ nil) do
    with %Ecto.Changeset{valid?: true} = cs <-
           Bonfire.Data.Assort.Ranked.changeset(%{
             item_id: uid(choice),
             scope_id: uid(question),
             rank_set: position
           })
           |> Ecto.Changeset.unique_constraint([:item_id, :scope_id],
             name: :bonfire_data_ranked_unique_per_scope
           )
           # |> Ecto.Changeset.apply_action(:insert)
           |> debug("Ranked cs"),
         {:ok, ins} <- repo().insert(cs) do
      # TODO: federate
      {:ok, ins}
    else
      # poor man's upsert - TODO fix drag and drop ordering and make better and generic
      {:error, %Ecto.Changeset{} = cs} ->
        warn(cs, "Ranked cs error")
        repo().upsert(cs, [:rank])

      # TODO: federate

      %Ecto.Changeset{} = cs ->
        warn(cs, "Ranked cs error2")

        repo().upsert(cs, [:rank])

      # TODO: federate

      e ->
        error(e)
    end
    |> debug()
  end

  @doc """
  Removes the association between a choice and a question.
  Deletes the Ranked record linking the choice to the question.
  Returns :ok if deleted, {:error, reason} otherwise.
  """
  def remove_choice(choice_id, question_id) do
    repo = repo()

    assoc =
      repo.get_by(Bonfire.Data.Assort.Ranked, item_id: uid(choice_id), scope_id: uid(question_id))

    case assoc do
      nil ->
        {:error, :not_found}

      _ ->
        case repo.delete(assoc, allow_stale: true) do
          # TODO: federate
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def find_choice_by_name(question, name) do
    question = repo().maybe_preload(question, :choices)

    case Enum.find(question.choices, fn c ->
           e(c, :post_content, :name, nil) || e(c, :post_content, :summary, nil) ||
             e(c, :post_content, :html_body, nil) == name
         end) do
      nil -> {:error, :not_found}
      choice -> {:ok, choice}
    end
  end
end
