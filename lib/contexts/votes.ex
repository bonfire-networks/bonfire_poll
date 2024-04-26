defmodule Bonfire.Poll.Votes do
  use Bonfire.Common.Utils
  import Bonfire.Poll.Integration
  alias Bonfire.Poll.{Question, Vote}
  alias Ecto.Changeset
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds

  # TODO: configurable
  def scores,
    do: [
      {"∞", "Block", "fontisto:ban",
       "I need to express a veto, because this would harm a person or group, or it goes against our shared values or goals"},
      #   {-3, "Strongly Disagree", "fontisto:rage", "I'm sure this would be a big mistake"},
      {-2, "Disagree", "fontisto:frowning", "I am strongly opposed"},
      {-1, "Concerned", "fontisto:confused",
       "I think this may be a mistake, or I have a different opinion"},
      {0, "Neutral", "fontisto:neutral", "Not relevant to me, I don't have an opinion"},
      {1, "Seems fine", "fontisto:slightly-smile", "I'm OK to try this for now"},
      {2, "Great", "fontisto:heart-eyes",
       "This meets my needs and aligns with my values and goals"}
      # {1, "Seems fine", "fontisto:slightly-smile", ""},
      # {2, "Sounds good", "fontisto:smiley", ""},
      # {3, "Awesome", "fontisto:heart-eyes", ""}
    ]

  def get_score(value, scores \\ scores()) do
    Enum.find(scores, fn
      {value, _, _, _} -> true
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
  #       vote(voter, question, choices, opts)
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
      vote(voter, question, choices, opts)
    else
      _ ->
        error(question, l("Sorry, you cannot vote on this"))
    end
  end

  def vote(voter, question, choices, opts) do
    # multiple choice
    with {:ok, votes} <-
           choices
           |> load_choices(voter, opts)
           |> debug("loaded_choices")
           |> Enum.map(&register_vote_choice(voter, question, &1, opts))
           |> only_ok()
           |> debug("oks"),
         #  |> Enum.split_with(fn # TODO: more generic
         #    {:ok, _} -> true
         #    _ -> false
         #  end),
         {:ok, vote_activity} <- send_vote_activity(voter, question, votes, opts) do
      {:ok, vote_activity}
    end
  end

  defp load_choices({choice, weight}, voter, opts) do
    load_choices([{choice, weight}], voter, opts)
  end

  defp load_choices(choice, voter, opts) when is_struct(choice) do
    load_choices([{choice, 1}], voter, opts)
  end

  defp load_choices(choices_weights, voter, opts)
       when is_list(choices_weights) or is_map(choices_weights) do
    choices_weights = Enum.into(choices_weights, %{})
    # assumes choices contains choice IDs as key and weight as values
    choices_weights
    #  TODO: if choices are already loaded, use those (and maybe re-check boundaries) instead of reloading them
    |> Map.keys()
    |> Bonfire.Boundaries.load_pointers!(
      opts ++
        [
          current_user: voter,
          #  verbs: [:vote]
          # FIXME: temp until we run fixtures with vote verb
          skip_boundary_check: true
          #  verbs: [:read]
        ]
    )
    |> Objects.preload_creator()
    |> debug()
    |> Enum.map(fn %{id: id} = choice ->
      {choice, choices_weights[id]}
    end)
  end

  def register_vote_choice(voter, question, choice, opts \\ [])

  def register_vote_choice(%{} = voter, %{} = question, {choice, weight}, opts) do
    case do_create_vote_choice(voter, choice, weight, opts) do
      {:ok, vote} ->
        {:ok, vote}

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

  defp do_create_vote_choice(voter, choice, weight, opts) do
    # don't create an activity or set ACLs on each individual vote on a choice, since we do that in `send_vote_activity/4` instead
    Edges.changeset_base_with_creator(Vote, voter, choice, opts)
    |> Vote.changeset(%{vote_weight: weight})
    |> debug("csss")
    |> Edges.insert(voter, choice)
  end

  def send_vote_activity(%{} = voter, %{} = question, registered_votes, opts) do
    question = Objects.preload_creator(question)
    question_object_creator = Objects.object_creator(question)

    choice_creators =
      registered_votes
      |> List.wrap()
      |> Enum.map(&Objects.object_creator(e(&1, :edge, :object, nil)))

    opts =
      [
        # TODO: make configurable
        boundary: "mentions",
        to_circles: [Enums.id(question_object_creator), Enums.ids(choice_creators)],
        to_feeds:
          Feeds.maybe_creator_notification(
            voter,
            [question_object_creator, choice_creators],
            opts
          )
      ] ++ List.wrap(opts)

    case do_create_vote_activity(voter, question, opts) do
      {:ok, vote_activity} ->
        vote_activity =
          vote_activity
          |> Map.put(:votes, registered_votes)

        {:ok, vote_activity}

      # Integration.maybe_federate_and_gift_wrap_activity(voter, vote_activity)

      {:error, e} ->
        case get(voter, question) do
          {:ok, vote_activity} ->
            {:ok,
             vote_activity
             |> debug("the user already voted on this")
             |> Map.put(:votes, registered_votes)}

          _ ->
            error(e)
        end
    end
  end

  defp do_create_vote_activity(voter, question, opts) do
    Edges.changeset(Vote, voter, :vote, question, opts)
    |> debug("csss")
    |> Edges.insert(voter, question)
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Vote, filters, opts)
  end

  def query(filters, opts) do
    query_base(filters, opts)
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

  def calculate_total(nil, _weighting, nil), do: nil
  def calculate_total(_vote_weight, _weighting, nil), do: nil

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
