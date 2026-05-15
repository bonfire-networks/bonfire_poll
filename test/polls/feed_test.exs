defmodule Bonfire.Poll.FeedTest do
  use Bonfire.Poll.DataCase, async: true
  use Bonfire.Common.E

  import Bonfire.Me.Fake
  import Bonfire.Poll.Fake

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Poll.Questions

  test "poll object in feed is a resolved Question struct, not a bare Needle.Pointer" do
    user = fake_user!()
    {:ok, question} = fake_question(%{}, current_user: user)

    %{edges: edges} = FeedLoader.feed_postloaded(:local, current_user: user)

    poll_edge =
      Enum.find(edges, fn edge ->
        e(edge, :activity, :object_id, nil) == question.id
      end)

    assert poll_edge, "poll should appear in local feed"

    object = e(poll_edge, :activity, :object, nil)

    assert %Bonfire.Poll.Question{} = object,
           "feed object should be a resolved Question struct, got: #{inspect(object.__struct__)}"
  end

  test "poll choices are preloaded when loading feed with component preloads" do
    user = fake_user!()

    {:ok, question} =
      fake_question_with_choices(%{}, [%{name: "Option A"}, %{name: "Option B"}],
        current_user: user
      )

    %{edges: edges} =
      FeedLoader.feed_postloaded(:local,
        current_user: user,
        preload_nested:
          {[:activity, :object],
           [{Bonfire.Poll.Question, Bonfire.Poll.Web.Preview.QuestionLive.preloads()}]}
      )

    poll_edge =
      Enum.find(edges, fn edge ->
        e(edge, :activity, :object_id, nil) == question.id
      end)

    assert poll_edge, "poll should appear in local feed"
    object = e(poll_edge, :activity, :object, nil)
    assert %Bonfire.Poll.Question{} = object
    assert is_list(object.choices) and length(object.choices) == 2,
           "choices should be preloaded, got: #{inspect(object.choices)}"
  end

  test "voting_open? and proposal_open? do not crash on poll loaded from feed" do
    user = fake_user!()

    {:ok, _question} =
      fake_question(
        %{
          proposal_dates: [
            DateTime.utc_now() |> DateTime.add(-60, :second),
            DateTime.utc_now() |> DateTime.add(3600, :second)
          ]
        },
        current_user: user
      )

    %{edges: edges} = FeedLoader.feed_postloaded(:local, current_user: user)

    for edge <- edges do
      object = e(edge, :activity, :object, nil)
      # these must not raise FunctionClauseError
      Questions.voting_open?(object)
      Questions.proposal_open?(object)
    end
  end
end
