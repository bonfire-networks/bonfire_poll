defmodule Bonfire.Poll.Votes do
  use Bonfire.Common.Utils
  import Bonfire.Poll.Integration
  alias Bonfire.Poll.{Question, Vote}
  alias Ecto.Changeset
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  def by_voter(subject, opts \\ []) when is_map(subject) or is_binary(subject),
    do:
      (opts ++ [subject: subject])
      |> query([current_user: subject] ++ List.wrap(opts))
      |> repo().many()

  def count(filters \\ [], opts \\ [])

  def count(filters, opts) when is_list(filters) and is_list(opts) do
    Edges.count(__MODULE__, filters, opts)
  end

  def count(%{} = user, object) when is_struct(object) or is_binary(object),
    do: Edges.count_for_subject(__MODULE__, user, object, skip_boundary_check: true)

  def count(%{} = object, _), do: Edges.count(:vote, object, skip_boundary_check: true)

  def vote(voter, question, choices, opts \\ [])

  #   def vote(%{} = voter, %{} = question, choices, opts) do
  #     if Bonfire.Boundaries.can?(voter, :vote, question) do
  #       do_vote(voter, question, choices, opts)
  #     else
  #       error(l("Sorry, you cannot vote on this"))
  #     end
  #   end

  def vote(%{} = voter, question, choices, opts) when is_binary(question) do
    with {:ok, question} <-
           Bonfire.Common.Needles.get(
             question,
             opts ++
               [
                 current_user: voter,
                 #  verbs: [:vote]
                 # FIXME: temp until we run fixtures with vote verb
                 verbs: [:read]
               ]
           ) do
      # debug(choice)
      do_vote(voter, question, choices, opts)
    else
      _ ->
        error(l("Sorry, you cannot vote on this"))
    end
  end

  #   def vote(%{} = voter, question, choice, opts) when is_binary(choice) do
  #     with {:ok, choice} <-
  #            Bonfire.Common.Needles.get(
  #              choice,
  #              opts ++
  #                [
  #                  current_user: voter,
  #                 #  verbs: [:vote]
  #                 skip_boundary_check: true # since we already check on the question
  #                ]
  #            ) do
  #       # debug(choice)
  #       do_vote(voter, question, choice, opts)
  #     else
  #       _ ->
  #         error(l("Sorry, that choice was not found"))
  #     end
  #   end

  def do_vote(voter, question, choice, opts \\ [])

  def do_vote(%{} = voter, %{} = question, {choice, weight}, opts) do
    question = Objects.preload_creator(question)
    question_object_creator = Objects.object_creator(question)

    choice = Objects.preload_creator(choice)
    choice_object_creator = Objects.object_creator(choice)

    opts =
      [
        # TODO: make configurable
        boundary: "mentions",
        to_circles: [id(question_object_creator), id(choice_object_creator)]
        # to_feeds: Feeds.maybe_creator_notification(voter, [question_object_creator, choice_object_creator], opts)
      ] ++ List.wrap(opts)

    case create(voter, choice, weight, opts) do
      {:ok, vote} ->
        {:ok, vote}

      # Integration.maybe_federate_and_gift_wrap_activity(voter, vote)

      {:error, e} ->
        case get(voter, choice) do
          {:ok, vote} ->
            debug(vote, "the user already voted on this")
            {:ok, vote}

          _ ->
            error(e)
            {:error, e}
        end
    end
  end

  def do_vote(%{} = voter, %{} = question, choice, opts) do
    do_vote(voter, question, {choice, 1}, opts)
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Vote, filters, opts)
  end

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(voter, choice, weight, opts) do
    # so votes don't get deleted if a voter is deleted
    Edges.changeset_without_caretaker(Vote, voter, :vote, choice, opts)
    |> Ecto.Changeset.cast(%{vote_weight: weight}, [:vote_weight])
    |> Edges.insert()
  end
end
