defmodule Bonfire.Poll.Web.WidgetPollsClosingSoonLive do
  @moduledoc """
  Dashboard widget showing open polls ordered by closing time (soonest
  first). The default limit is 3; pass `limit={N}` to override.

  Renders nothing when there are no qualifying polls — the surrounding
  page lays out cleanly without a stub.
  """
  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Poll.Questions
  alias Bonfire.Poll.Web.Preview.QuestionLive

  prop limit, :integer, default: 3
  prop widget_title, :string, default: nil

  @doc """
  Returns `%{polls: [...], counts: %{question_id => n}}` — the poll rows
  plus a single grouped vote-count map keyed by question id. Two queries
  total regardless of poll popularity.
  """
  def load(current_user, limit) do
    polls = Questions.list_closing_soon([current_user: current_user], limit)
    counts = Questions.vote_counts_for_questions(Enum.map(polls, & &1.id))
    %{polls: polls, counts: counts}
  end

  @doc "Closing-time label for a poll. Mirrors QuestionLive.time_remaining/1."
  def closes_in(question) do
    case e(question, :voting_dates, nil) do
      [_start, end_dt] -> QuestionLive.time_remaining(end_dt)
      _ -> nil
    end
  end

  @doc "Localised, singular-aware vote-count label (delegates to QuestionLive)."
  defdelegate pluralize_votes(n), to: QuestionLive

  @doc "Username of the user who created the poll, or nil."
  def author_username(question),
    do: e(question, :created, :creator, :character, :username, nil)

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
