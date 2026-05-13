defmodule Bonfire.Poll.Web.Preview.QuestionLive do
  use Bonfire.UI.Common.Web, :stateless_component
  alias Bonfire.Poll.Questions
  alias Bonfire.Poll.Web.Preview.ChoiceLive

  prop object, :any
  prop activity_component_id, :any, default: nil
  prop activity, :any, default: nil
  prop viewing_main_object, :boolean, default: false
  prop showing_within, :atom, default: nil
  prop cw, :boolean, default: nil
  prop is_remote, :boolean, default: false
  prop thread_title, :any, default: nil
  prop hide_actions, :boolean, default: false
  prop activity_inception, :boolean, default: false

  def preloads(),
    do: [
      :post_content,
      choices: [
        :post_content,
        object_voted: [:vote],
        created: [creator: [:profile, :character]]
      ]
    ]

  def post_content(object) do
    e(object, :post_content, nil) || object
  end

  @doc "Pre-compute every value the template branches read, so the .sface stays flat."
  def view_state(question) do
    choices = e(question, :choices, []) || []
    remote_stats = remote_poll_stats(question)
    end_time = end_time(question, remote_stats)

    %{
      choices: choices,
      has_voted: voted?(choices),
      remote_stats: remote_stats,
      end_time: end_time,
      closed: closed?(end_time),
      locked: results_locked?(question, end_time),
      winning_ids: winning_choice_ids(choices),
      voting_format: e(question, :voting_format, nil) || Questions.default_voting_format(),
      total_votes: max(total_votes(choices), remote_stats.total_votes)
    }
  end

  @doc "Vote count for a choice, taking the higher of local and remote-stats counts."
  def choice_vote_count(choice, remote_stats \\ %{})

  def choice_vote_count(choice, %{choice_counts: choice_counts}) when is_map(choice_counts) do
    name = e(choice, :post_content, :name, nil)
    max(local_vote_count(choice), Map.get(choice_counts, name, 0))
  end

  def choice_vote_count(choice, _), do: local_vote_count(choice)

  defp local_vote_count(choice) do
    case e(choice, :object_voted, nil) do
      votes when is_list(votes) -> length(votes)
      _ -> 0
    end
  end

  @doc "Sum of per-choice vote counts."
  def total_votes(choices) when is_list(choices),
    do: choices |> Enum.map(&choice_vote_count/1) |> Enum.sum()

  def total_votes(_), do: 0

  @doc "Get remote poll stats from cached AP object"
  def remote_poll_stats(question) do
    with question_id when is_binary(question_id) <- id(question),
         {:ok, %{data: data}} when is_map(data) <-
           ActivityPub.Object.get_cached(pointer: question_id) do
      options =
        case Questions.options_key_from_ap_data(data) do
          nil -> []
          key -> data[key] || []
        end

      choice_counts = Map.new(options, &ap_option_count/1)
      total = Enum.sum(Map.values(choice_counts))

      %{
        voters_count: data["votersCount"] || total,
        total_votes: total,
        choice_counts: choice_counts,
        end_time: data["endTime"]
      }
    else
      _ -> %{voters_count: 0, total_votes: 0, choice_counts: %{}, end_time: nil}
    end
  end

  defp ap_option_count(opt) do
    count =
      case get_in(opt, ["replies", "totalItems"]) do
        n when is_integer(n) -> n
        _ -> 0
      end

    {opt["name"], count}
  end

  @doc "True when the current user has already cast a vote on at least one choice."
  def voted?(choices) when is_list(choices), do: Enum.any?(choices, &voted_on?/1)
  def voted?(_), do: false

  @doc "True when the current user has voted on this specific choice."
  def voted_on?(choice), do: match?([_ | _], e(choice, :object_voted, nil))

  @doc "True when the poll's deadline has passed."
  def closed?(end_time) when is_binary(end_time) do
    case DateTime.from_iso8601(end_time) do
      {:ok, dt, _} -> closed?(dt)
      _ -> false
    end
  end

  def closed?(%DateTime{} = end_time),
    do: DateTime.compare(end_time, DateTime.utc_now()) == :lt

  def closed?(_), do: false

  @doc """
  True when results should be hidden until close and the poll is still open.
  The Question schema doesn't persist `hide_results` yet (it lives in the
  composer's tuning state), so this is `false` until that field is added.
  """
  def results_locked?(question, end_time) do
    e(question, :hide_results, false) and not closed?(end_time)
  end

  @doc "Resolve the deadline from a question. Falls back to remote stats `end_time`."
  def end_time(question, remote_stats \\ %{})

  def end_time(_question, %{end_time: end_time}) when not is_nil(end_time), do: end_time

  def end_time(question, _) do
    case e(question, :voting_dates, nil) do
      [_start, %DateTime{} = end_dt] -> end_dt
      [_start, end_str] when is_binary(end_str) -> end_str
      _ -> nil
    end
  end

  @doc "Ids of choice(s) tied at the highest vote count; `[]` when no votes."
  def winning_choice_ids(choices, count_fn \\ &choice_vote_count/1)

  def winning_choice_ids(choices, count_fn) when is_list(choices) do
    counts = Enum.map(choices, fn c -> {id(c), count_fn.(c)} end)

    case Enum.max_by(counts, fn {_, n} -> n end, fn -> {nil, 0} end) do
      {_, 0} -> []
      {_, top} -> for {choice_id, ^top} <- counts, do: choice_id
    end
  end

  def winning_choice_ids(_, _), do: []

  @doc "True when any choice received a veto (`∞` sentinel) on a weighted poll."
  def vetoed?(choices) when is_list(choices), do: Enum.any?(choices, &choice_vetoed?/1)
  def vetoed?(_), do: false

  @doc "True when this specific choice received any veto vote (`vote_weight: nil`)."
  def choice_vetoed?(choice) do
    case e(choice, :object_voted, nil) do
      votes when is_list(votes) -> Enum.any?(votes, &veto_vote?/1)
      _ -> false
    end
  end

  defp veto_vote?(%{vote: %{vote_weight: nil}}), do: true
  defp veto_vote?(_), do: false

  @doc "Calculate time remaining for a poll"
  def time_remaining(nil), do: nil

  def time_remaining(end_time) when is_binary(end_time) do
    case DateTime.from_iso8601(end_time) do
      {:ok, dt, _} -> time_remaining(dt)
      _ -> nil
    end
  end

  def time_remaining(%DateTime{} = end_time) do
    now = DateTime.utc_now()

    case DateTime.compare(end_time, now) do
      :lt ->
        l("Closed")

      :eq ->
        l("Closing now")

      :gt ->
        diff = DateTime.diff(end_time, now, :second)

        cond do
          diff < 3600 -> l("%{count} minutes left", count: div(diff, 60))
          diff < 86400 -> l("%{count} hours left", count: div(diff, 3600))
          true -> l("%{count} days left", count: div(diff, 86400))
        end
    end
  end

  def time_remaining(_), do: nil
end
