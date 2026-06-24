defmodule Bonfire.Poll.Web.WidgetPollsClosingSoonLive do
  @moduledoc """
  Dashboard widget showing open polls ordered by closing time (soonest
  first). The default limit is 3; pass `limit={N}` to override.

  Renders nothing when there are no qualifying polls — the surrounding
  page lays out cleanly without a stub.
  """
  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Poll.Questions
  alias Bonfire.Poll.Votes
  alias Bonfire.Poll.Web.Preview.QuestionLive

  prop limit, :integer, default: 3
  prop widget_title, :string, default: nil

  @doc """
  Returns `%{polls: [...], counts: %{question_id => n}, voted_ids: MapSet}` —
  the poll rows plus a grouped vote-count map keyed by question id, and the set
  of polls the viewer has already weighed in on.

  Polls + counts are cached per user and limit for 1 hour; `voted_ids` is read
  fresh on each render so a viewer's "you've voted" state never lags their vote.
  """
  def load(current_user, limit) do
    result = Questions.closing_soon_widget(current_user, limit)

    voted_ids = Votes.voted_question_ids(current_user, Enum.map(result.polls, & &1.id))
    Map.put(result, :voted_ids, voted_ids)
  end

  @doc "Busts the closing-soon cache for the current viewer (recomputed lazily on next read)."
  def handle_event("reset_polls_closing_soon", params, socket) do
    Questions.closing_soon_widget(current_user(socket), reset_limit(params), cache: :reset)

    {:noreply,
     assign_flash(
       socket,
       :info,
       l("Polls have been reset.") <> l(" You need to reload to see updates, if any.")
     )}
  end

  defp reset_limit(%{"limit" => limit}) when is_binary(limit), do: String.to_integer(limit)
  defp reset_limit(_), do: 3

  @doc "Closing-time label for a poll. Mirrors QuestionLive.time_remaining/1."
  def closes_in(question) do
    case e(question, :voting_dates, nil) do
      [_start, end_dt] -> QuestionLive.time_remaining(end_dt)
      _ -> nil
    end
  end

  @doc """
  The decision kind as `{label, icon}` — consent decisions read differently from
  tally polls, so the widget names and ices them apart at a glance.
  """
  def kind(question) do
    case voting_format(question) do
      "weighted_multiple" -> {l("Consent"), "ph:handshake-duotone"}
      _ -> {l("Poll"), "ph:chart-bar-duotone"}
    end
  end

  @doc "Participation label in the poll's own noun (reactions for consent, else votes)."
  def count_label(question, counts),
    do: QuestionLive.count_label(voting_format(question), total_votes(question, counts))

  @doc "True when the viewer has already cast a vote on this poll."
  def voted?(voted_ids, question), do: MapSet.member?(voted_ids, id(question))

  defp voting_format(question),
    do: e(question, :voting_format, nil) || Questions.default_voting_format()

  @doc "Total votes for a question, read from the pre-computed counts map."
  def total_votes(question, counts), do: Map.get(counts, question.id, 0)

  @doc """
  Tailwind class for the closing-time label, escalating as we approach
  the deadline. Helps the row signal urgency at a glance.
  """
  def urgency_class(question) do
    with [_start, end_dt] <- e(question, :voting_dates, nil),
         :gt <- DateTime.compare(end_dt, DateTime.utc_now()) do
      diff = DateTime.diff(end_dt, DateTime.utc_now(), :second)

      cond do
        diff < 3600 -> "text-error font-medium"
        diff < 21_600 -> "text-warning"
        true -> "text-base-content/60"
      end
    else
      _ -> "text-base-content/55"
    end
  end
end
