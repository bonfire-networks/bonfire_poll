if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Poll.API.GraphQL.VoteTest do
    use Bonfire.Poll.DataCase, async: false

    import Bonfire.Me.Fake
    import Bonfire.Poll.Fake

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @vote """
    mutation($poll_id: String!, $votes: [VoteInput]) {
      vote(poll_id: $poll_id, votes: $votes) {
        id
      }
    }
    """

    @poll_state """
    query($id: ID!) {
      poll(filter: {id: $id}) {
        id
        voted
        votes_count
        own_votes {
          id
        }
      }
    }
    """

    test "vote returns a non-empty activity id and persists viewer vote state" do
      author = fake_user!()
      voter = fake_user!()
      {:ok, poll} = open_poll(author)
      choice = hd(poll.choices)

      {:ok, result} =
        Absinthe.run(@vote, Schema,
          variables: %{
            "poll_id" => poll.id,
            "votes" => [%{"choice_id" => choice.id, "weight" => "1"}]
          },
          context: Schema.context(%{current_user: voter})
        )

      refute result[:errors]
      assert get_in(result, [:data, "vote", "id"]) |> non_empty_string?()

      {:ok, state} =
        Absinthe.run(@poll_state, Schema,
          variables: %{"id" => poll.id},
          context: Schema.context(%{current_user: voter})
        )

      refute state[:errors]
      assert get_in(state, [:data, "poll", "id"]) == poll.id
      assert get_in(state, [:data, "poll", "voted"]) == true
      assert get_in(state, [:data, "poll", "votes_count"]) == 1
      assert [%{"id" => choice_id}] = get_in(state, [:data, "poll", "own_votes"])
      assert choice_id == choice.id
    end

    test "closed poll vote returns a GraphQL error instead of a success-shaped null" do
      author = fake_user!()
      voter = fake_user!()
      past_start = DateTime.utc_now() |> DateTime.add(-7200, :second)
      past_end = DateTime.utc_now() |> DateTime.add(-3600, :second)

      assert {:ok, poll} =
               fake_question_with_choices(
                 %{voting_dates: [past_start, past_end]},
                 [%{name: "Closed option"}],
                 current_user: author
               )

      choice = hd(poll.choices)

      {:ok, result} =
        Absinthe.run(@vote, Schema,
          variables: %{
            "poll_id" => poll.id,
            "votes" => [%{"choice_id" => choice.id, "weight" => "1"}]
          },
          context: Schema.context(%{current_user: voter})
        )

      assert result[:errors]
      assert get_in(result, [:data, "vote"]) == nil
    end

    test "missing vote choices return a GraphQL error instead of crashing" do
      voter = fake_user!()

      {:ok, result} =
        Absinthe.run(@vote, Schema,
          variables: %{"poll_id" => Ecto.UUID.generate(), "votes" => []},
          context: Schema.context(%{current_user: voter})
        )

      assert result[:errors]
      assert get_in(result, [:data, "vote"]) == nil
    end

    defp open_poll(author) do
      fake_question_with_choices(
        %{voting_dates: [DateTime.utc_now()]},
        [%{name: "Option A"}, %{name: "Option B"}],
        current_user: author
      )
    end

    defp non_empty_string?(value), do: is_binary(value) and value != ""
  end
end
