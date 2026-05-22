defmodule Bonfire.Poll.Web.Preview.QuestionLive do
  use Bonfire.UI.Common.Web, :stateless_component
  alias Bonfire.Poll.Questions
  alias Bonfire.Poll.Votes
  alias Bonfire.Poll.Web.Preview.ChoiceLive

  prop object, :any
  prop activity_component_id, :any, default: nil
  prop activity, :any, default: nil
  prop viewing_main_object, :boolean, default: false
  prop showing_within, :atom, default: nil
  prop cw, :boolean, default: nil
  prop is_remote, :boolean, default: false
  prop vote_state, :any, default: nil
  prop thread_title, :any, default: nil
  prop hide_actions, :boolean, default: false
  prop activity_inception, :boolean, default: false

  def preloads(),
    do: [
      :post_content,
      # :peered, # not sure if needed?
      choices: [
        :post_content,
        # Vote state is loaded through `Votes.preview_vote_state_for_*`, not
        # `object_voted`, so totals and viewer state stay explicitly scoped.
        created: [creator: [:profile, :character]]
      ]
    ]

  def post_content(object) do
    e(object, :post_content, nil) || object
  end

  @doc "Pre-compute every value the template branches read, so the .sface stays flat."
  def view_state(question, is_remote \\ false, current_user \\ nil, vote_state \\ nil) do
    choices = e(question, :choices, []) || []
    remote_stats = if is_remote, do: remote_poll_stats(question), else: empty_remote_stats()
    end_time = end_time(question, remote_stats)
    voting_format = e(question, :voting_format, nil) || Questions.default_voting_format()

    vote_state = preview_vote_state(question, is_remote, current_user, vote_state)
    local_counts = e(vote_state, :counts_by_choice_id, %{})

    vetoed_ids =
      if voting_format == "weighted_multiple",
        do: choice_ids(e(vote_state, :vetoed_choice_ids, [])),
        else: []

    my_votes =
      vote_state
      |> e(:my_vote_weights, %{})
      |> Map.new(fn {choice_id, weight} -> {choice_id, weight_to_score(weight)} end)

    counts_by_choice_id =
      Map.new(choices, fn c ->
        {id(c), choice_vote_count(c, remote_stats, Map.get(local_counts, id(c), 0))}
      end)

    total_votes = max(Enum.sum(Map.values(counts_by_choice_id)), remote_stats.total_votes)

    closed = closed?(end_time)
    locked = results_locked?(question, end_time)
    results_visible = (closed or my_votes != %{}) and not locked

    %{
      choices: choices,
      has_voted: my_votes != %{},
      counts_by_choice_id: counts_by_choice_id,
      my_votes: my_votes,
      vetoed_ids: vetoed_ids,
      end_time: end_time,
      closed: closed,
      locked: locked,
      results_visible: results_visible,
      results_toggleable: not closed and my_votes == %{} and not locked,
      winning_ids: winning_choice_ids(choices, &Map.get(counts_by_choice_id, id(&1), 0)),
      voting_format: voting_format,
      total_votes: total_votes,
      proposal_open: Questions.proposal_open?(question),
      time_remaining_label: time_remaining(end_time),
      proposal_end_label: time_remaining(List.last(e(question, :proposal_dates, []))),
      question_without_choices: Map.drop(question, [:choices])
    }
  end

  defp preview_vote_state(_question, true, _current_user, _vote_state),
    do: Votes.empty_preview_vote_state()

  defp preview_vote_state(question, _is_remote, _current_user, vote_state) when is_map(vote_state) do
    if Map.has_key?(vote_state, :counts_by_choice_id) do
      vote_state
    else
      Map.get(vote_state, id(question), Votes.empty_preview_vote_state())
    end
  end

  defp preview_vote_state(question, _is_remote, current_user, _vote_state),
    do: Votes.preview_vote_state_for_question(question, current_user)

  defp choice_ids(%MapSet{} = ids), do: MapSet.to_list(ids)
  defp choice_ids(ids) when is_list(ids), do: ids
  defp choice_ids(_), do: []

  defp empty_remote_stats,
    do: %{voters_count: 0, total_votes: 0, choice_counts: %{}, end_time: nil}

  @doc "Vote count for a choice: the higher of local aggregate and remote stats."
  def choice_vote_count(choice, remote_stats \\ %{}, local_count \\ 0)

  def choice_vote_count(choice, %{choice_counts: choice_counts}, local_count)
      when is_map(choice_counts) do
    name = e(choice, :post_content, :name, nil)
    max(local_count || 0, Map.get(choice_counts, name, 0))
  end

  def choice_vote_count(_choice, _remote_stats, local_count),
    do: local_count || 0

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

  @doc """
  Maps a stored `vote_weight` to the score shown in the UI: `"∞"` for a veto
  (the schema stores it as `nil`), otherwise the integer weight as-is.
  """
  def weight_to_score(nil), do: "∞"
  def weight_to_score(weight) when is_integer(weight), do: weight

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
          diff < 3600 ->
            n = div(diff, 60)
            lp("1 minute left", "%{count} minutes left", n, count: n)

          diff < 86400 ->
            n = div(diff, 3600)
            lp("1 hour left", "%{count} hours left", n, count: n)

          true ->
            n = div(diff, 86400)
            lp("1 day left", "%{count} days left", n, count: n)
        end
    end
  end

  def time_remaining(_), do: nil

  @doc "Localised, singular-aware vote count: `1 vote` / `N votes`."
  def pluralize_votes(n), do: lp("1 vote", "%{count} votes", n, count: n)
end
