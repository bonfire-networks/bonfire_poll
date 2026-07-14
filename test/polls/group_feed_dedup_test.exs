defmodule Bonfire.Poll.GroupFeedDedupTest do
  @moduledoc """
  When a poll is created inside a group, two activities reference the same object:
    1. the create activity by the author
    2. the group's auto-boost (the poll epic runs `Bonfire.Tags.Acts.AutoBoost`)
  The "my" feed must collapse these into a single entry, just like plain posts
  (see mayel's `dedup feed by object` fix in `Bonfire.Social.FeedLoader`).
  """
  use Bonfire.Poll.DataCase, async: true
  use Bonfire.Common.E

  import Bonfire.Me.Fake
  import Bonfire.Poll.Fake

  alias Bonfire.Social.FeedLoader

  setup do
    Process.put(:federating, false)
    Process.put([:bonfire, :feed_live_update_many_preload_mode], :inline)
    :ok
  end

  defp object_occurrences(edges, object_id) do
    Enum.filter(edges, fn edge ->
      e(edge, :activity, :object_id, nil) == object_id or
        e(edge, :activity, :object, :id, nil) == object_id
    end)
  end

  test "a poll created in a group appears only once in the author's feed" do
    creator = fake_user!()
    group = Bonfire.Classify.Simulate.fake_group!(creator, %{visibility: "global"})

    {:ok, question} =
      fake_question(%{post_content: %{name: "Poll in a group?"}},
        current_user: creator,
        context_id: group.id,
        to_circles: [group.id],
        boundary: "public"
      )

    %{edges: edges} =
      FeedLoader.feed(:my, %{show_objects_only_once: true}, current_user: creator)

    assert length(object_occurrences(edges, question.id)) == 1
  end

  test "a reply to a poll created in a group appears only once in the author's feed" do
    creator = fake_user!()
    group = Bonfire.Classify.Simulate.fake_group!(creator, %{visibility: "global"})

    {:ok, question} =
      fake_question(%{post_content: %{name: "Poll to reply to?"}},
        current_user: creator,
        context_id: group.id,
        to_circles: [group.id],
        boundary: "public"
      )

    # reply to the poll post, published in the group context (triggers the group
    # auto-boost of the reply, which previously made it appear twice)
    {:ok, reply} =
      Bonfire.Posts.publish(
        current_user: creator,
        post_attrs: %{
          reply_to_id: question.id,
          post_content: %{html_body: "<p>A reply to the poll</p>"}
        },
        context_id: group.id,
        to_circles: [group.id],
        boundary: "public"
      )

    %{edges: edges} =
      FeedLoader.feed(:my, %{show_objects_only_once: true}, current_user: creator)

    assert length(object_occurrences(edges, reply.id)) == 1
  end
end
