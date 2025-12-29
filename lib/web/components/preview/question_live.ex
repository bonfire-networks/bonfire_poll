defmodule Bonfire.Poll.Web.Preview.QuestionLive do
  use Bonfire.UI.Common.Web, :stateless_component
  alias Bonfire.Poll.Questions

  prop object, :any
  prop activity_component_id, :any, default: nil
  prop activity, :any, default: nil
  prop viewing_main_object, :boolean, default: false
  prop showing_within, :atom, default: nil
  # prop activity_inception, :any, default: nil
  prop cw, :boolean, default: nil
  prop is_remote, :boolean, default: false
  prop thread_title, :any, default: nil
  # prop thread_mode, :atom, default: nil
  prop hide_actions, :boolean, default: false
  prop activity_inception, :boolean, default: false

  def preloads(),
    do: [
      :post_content,
      # :voted,
      choices: [:post_content, object_voted: [:vote]]
    ]

  def post_content(object) do
    e(object, :post_content, nil) || object
  end

  @doc "Calculate total votes count across all choices"
  def total_votes(choices) when is_list(choices) do
    choices
    |> Enum.map(&choice_vote_count/1)
    |> Enum.sum()
  end

  def total_votes(_), do: 0

  @doc "Get vote count for a single choice"
  def choice_vote_count(choice) do
    case e(choice, :object_voted, nil) do
      votes when is_list(votes) -> length(votes)
      _ -> 0
    end
  end

  @doc "Get remote poll stats from cached AP object"
  def remote_poll_stats(question) do
    with question_id when is_binary(question_id) <- id(question),
         {:ok, ap_object} <- ActivityPub.Object.get_cached(pointer: question_id),
         data when is_map(data) <- ap_object.data do
      options_key = Questions.options_key_from_ap_data(data)
      options = if options_key, do: data[options_key] || [], else: []

      choice_counts =
        options
        |> Enum.map(fn opt ->
          name = opt["name"]

          count =
            case get_in(opt, ["replies", "totalItems"]) do
              n when is_integer(n) -> n
              _ -> 0
            end

          {name, count}
        end)
        |> Map.new()

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

  @doc "Get vote count for a choice with optional remote stats"
  def choice_vote_count(choice, remote_stats)

  def choice_vote_count(choice, %{choice_counts: choice_counts} = _remote_stats)
      when is_map(choice_counts) do
    # Try local votes first
    local_votes =
      case e(choice, :object_voted, nil) do
        votes when is_list(votes) -> length(votes)
        _ -> 0
      end

    # Get remote count by choice name
    choice_name = e(choice, :post_content, :name, nil)
    remote_count = Map.get(choice_counts, choice_name, 0)

    # Use whichever is higher
    max(local_votes, remote_count)
  end

  def choice_vote_count(choice, _), do: choice_vote_count(choice)

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
