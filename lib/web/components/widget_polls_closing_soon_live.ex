defmodule Bonfire.Poll.Web.WidgetPollsClosingSoonLive do
  @moduledoc """
  Dashboard widget showing open polls ordered by closing time (soonest
  first), laid out as a horizontal snap carousel (same pattern as the
  "Spotlight" and "Who to follow" widgets). Each poll renders as the full
  standard poll preview (`Bonfire.Poll.Web.Preview.QuestionLive`) — the same
  component feeds use — so the status band, options, tallies and inline voting
  all match the rest of the app. The default limit is 3; pass `limit={N}` to
  override.

  Renders nothing when there are no qualifying polls — the surrounding page lays
  out cleanly without a stub.
  """
  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Poll.Questions
  alias Bonfire.Poll.Votes
  alias Bonfire.Poll.Web.Preview.QuestionLive

  prop limit, :integer, default: 3
  prop widget_title, :string, default: nil

  @doc """
  Returns `%{polls: [...], vote_state: %{question_id => state}}` — the poll rows
  plus the batched read model (`counts`, `vetoes`, the viewer's own votes and the
  score histograms) for all of them, keyed by question id for `QuestionLive` to
  look up.

  The poll list is cached per user and limit for 1 hour; `vote_state` is read
  fresh on each render — in 3 batched queries regardless of poll count — so
  tallies and the viewer's "you've voted" state never lag their vote.
  """
  def load(current_user, limit) do
    %{polls: polls} = Questions.closing_soon_widget(current_user, limit)
    vote_state = Votes.preview_vote_state_for_questions(polls, current_user)
    %{polls: polls, vote_state: vote_state}
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
end
