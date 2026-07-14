defmodule Bonfire.Poll.VoteFeedVisibilityTest do
  @moduledoc """
  A poll vote is a "quiet" interaction (like a Like): it notifies the poll
  creator but must NOT show up as an activity on the voter's profile or in the
  public/discovery feeds. Enforced by excluding the `:vote` verb from those feed
  presets in `Bonfire.Social.Feeds` config (`exclude_activity_types`).
  """
  use Bonfire.Poll.DataCase, async: true
  use Bonfire.Common.E
  import Bonfire.Me.Fake
  import Bonfire.Poll.Fake
  alias Bonfire.Poll.Votes
  alias Bonfire.Social.FeedLoader

  @vote_verb_id "7V0TEMEANSC0NSENT0RREFVSA1"

  setup do
    Process.put([:bonfire, :feed_live_update_many_preload_mode], :inline)
    :ok
  end

  defp has_vote_activity?(%{edges: edges}) do
    Enum.any?(edges, &(e(&1, :activity, :verb_id, nil) == @vote_verb_id))
  end

  test "a vote does not appear in feeds but still notifies the poll creator" do
    author = fake_user!()
    voter = fake_user!()
    stranger = fake_user!()

    {:ok, question} =
      fake_question_with_choices(%{voting_dates: [DateTime.utc_now()]}, [%{name: "A"}],
        current_user: author,
        boundary: "public"
      )

    [choice] = question.choices
    {:ok, _} = Votes.vote(voter, question, [%{choice_id: choice.id, weight: 1}])

    # Not on the voter's own profile timeline...
    refute has_vote_activity?(
             FeedLoader.feed(:user_activities, %{}, by: voter, current_user: voter)
           )

    # ...nor when a stranger views the voter's profile...
    refute has_vote_activity?(
             FeedLoader.feed(:user_activities, %{}, by: voter, current_user: stranger)
           )

    # ...nor in the public/local feed.
    refute has_vote_activity?(FeedLoader.feed(:local, %{}, current_user: stranger))
    refute has_vote_activity?(FeedLoader.feed(:explore, %{}, current_user: stranger))

    # ...nor in the polls feed (whose object type is Question).
    refute has_vote_activity?(FeedLoader.feed(:polls, %{}, current_user: stranger))

    # But the poll creator IS still notified.
    assert FeedLoader.feed_contains?(:notifications, question, current_user: author)
  end
end
