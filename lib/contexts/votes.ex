defmodule Bonfire.Poll.Votes do
  use Bonfire.Common.Utils
  import Bonfire.Poll.Integration
  alias Bonfire.Poll.{Question, Vote}
  alias Ecto.Changeset
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects

  def scores,
    do: [
      {"∞", "fontisto:ban",
       "Block: I have to veto this because it would harm somebody or the group, or goes against our shared values or goals"},
      #   {-3, "fontisto:rage", "Disagree: I'm sure this would be a big mistake"},
      {-2, "fontisto:frowning", "Disagree: I am strongly opposed"},
      {-1, "fontisto:confused",
       "Concerned: I think this would be a mistake or have a different opinion"},
      {0, "fontisto:neutral", "Step aside: not relevant to me, I don't have an opinion"},
      {1, "fontisto:slightly-smile", "Seems fine to me"},
      {2, "fontisto:smiley", "Sounds good"},
      {3, "fontisto:heart-eyes", "Awesome!"}
    ]

  def get_score(value, scores \\ scores()) do
    Enum.find(scores, fn
      {value, _, _} -> true
      _ -> false
    end)
  end

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
    |> Vote.changeset(%{vote_weight: weight})
    |> debug("csss")
    |> Edges.insert()
  end

  #   def get_total(proposal, votes, %{} = question) do
  #     proposal_id = id(proposal)
  #
  #     votes
  #     |> Enum.filter(fn vote -> vote.proposal_id == proposal_id end)
  #     |> get_total(question)
  #   end

  def calculate_total(votes, weighting, sum \\ 0)

  def calculate_total(votes, %{weighting: weighting} = _question, sum),
    do: calculate_total(votes, weighting, sum)

  def calculate_total(votes, weighting, sum) when is_list(votes) do
    votes
    |> Enum.reduce(sum, fn vote, sum ->
      calculate_total(vote, weighting, sum)
    end)
  end

  def calculate_total(%{vote_weight: vote_weight} = _vote, weighting, sum),
    do: calculate_total(vote_weight, weighting, sum)

  def calculate_total(%{vote: %{vote_weight: vote_weight} = vote}, weighting, sum),
    do: calculate_total(vote_weight, weighting, sum)

  def calculate_total(vote_weight, weighting, sum) do
    case vote_weight do
      nil -> nil
      vote when vote < 0 -> vote * weighting + sum
      vote -> vote + sum
    end
  end

  def get_average_base_score(nil, _num_voters), do: nil

  def get_average_base_score(total, num_voters) do
    if num_voters > 0 do
      i = total / num_voters
      #   round(i * 100) / 100
      round(i)
    else
      0
    end
  end

  #   def get_average_score(total, num_voters, %{} = question, scores) do
  #     avg = get_average_score(total, num_voters)
  #     avg = if avg < 0 do
  #       avg / question.weighting
  #     else
  #       avg
  #     end
  #   end

  def get_average_emoji(total, num_voters, %{} = question, scores \\ scores()) do
    case get_average_base_score(total, num_voters) do
      nil -> get_score("∞", scores)
      value -> get_score(round(value), scores)
    end
  end
end
