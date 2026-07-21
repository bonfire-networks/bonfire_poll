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

  @doc "Stable DOM id for a poll card — the anchor shared by the preview hook and its trigger."
  def poll_card_id(poll),
    do: deterministic_dom_id(__MODULE__, id(poll) || "no-id", "poll_preview")

  @doc """
  The poll's permalink, with the trailing `#` `ActivityLive` also appends (it
  marks the URL as a same-page preview target rather than a navigation).
  """
  def poll_permalink(poll) do
    case path(poll, [], preload_if_needed: false) do
      permalink when is_binary(permalink) -> "#{permalink}#"
      _ -> nil
    end
  end

  @doc "Title for the preview modal — the poll question, else a generic label."
  def poll_title(poll),
    do: e(QuestionLive.post_content(poll), :name, nil) || l("Poll")

  @doc """
  Assigns for the thread preview modal. Built by `ActivityLive` so this widget
  can't drift from how the same modal opens from a feed — via `maybe_apply/4`
  since `bonfire_ui_social` is not a dependency of this extension.

  There's no activity row here (the loader lists questions, not feed entries), so
  the poll is passed as the object and `ActivityLive` takes its top-of-thread
  branch — correct for a poll, which is always the root of its own thread.
  """
  def poll_preview_modal_assigns(poll, permalink) do
    object_id = id(poll)
    replied = e(poll, :replied, nil)
    thread_id = e(replied, :thread_id, nil) || id(e(replied, :thread, nil))

    maybe_apply(
      Bonfire.UI.Social.ActivityLive,
      :thread_preview_modal_assigns,
      [thread_id, object_id, object_id, nil, poll, nil],
      fallback_return: [
        thread_id: thread_id,
        object_id: thread_id || object_id,
        show: true,
        loaded: true,
        showing_within: :thread,
        object: poll
      ]
    ) ++
      [
        post_id: thread_id || object_id,
        current_url: permalink,
        cw: false
      ]
  end

  @doc "The poll's author, from the `created` assoc proloaded by `Questions.list_closing_soon/2`."
  def poll_creator(poll), do: e(poll, :created, :creator, nil)

  @doc "Display name for the byline, falling back to the username."
  def creator_name(creator),
    do: e(creator, :profile, :name, nil) || e(creator, :character, :username, nil)

  @doc "Avatar URL for the byline (generated fallback is handled by `AvatarLive`)."
  def creator_avatar(creator), do: Bonfire.Common.Media.avatar_url(creator)

  @doc "Profile path for the byline. Never `nil` — `LinkLive` requires a `to`."
  def creator_path(creator), do: path(creator, [], preload_if_needed: false) || "#"
end
