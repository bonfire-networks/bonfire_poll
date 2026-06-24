if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Poll.API.GraphQL.PollDetailTest do
    use Bonfire.Poll.DataCase, async: false

    import Bonfire.Me.Fake
    import Bonfire.Poll.Fake

    alias Bonfire.API.GraphQL.Schema
    alias Bonfire.Poll.Votes

    @moduletag :graphql

    @poll_detail """
    query($id: ID!) {
      poll(filter: {id: $id}) {
        id
        choices {
          id
          post_content {
            name
          }
        }
      }
    }
    """

    @weighted_poll_detail """
    query($id: ID!) {
      poll(filter: {id: $id}) {
        id
        choices {
          id
          post_content {
            name
          }
          votes_result_total
          votes_result_average
        }
        own_votes {
          id
          votes_result_total
          votes_result_average
        }
      }
    }
    """

    test "poll detail returns the referenced poll with usable choices" do
      user = fake_user!()

      assert {:ok, poll} =
               fake_question_with_choices(
                 %{post_content: %{name: "GraphQL poll detail"}},
                 [%{name: "Option A"}, %{name: "Option B"}],
                 current_user: user
               )

      {:ok, result} =
        Absinthe.run(@poll_detail, Schema,
          variables: %{"id" => poll.id},
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors]
      assert get_in(result, [:data, "poll", "id"]) == poll.id

      choices = get_in(result, [:data, "poll", "choices"])

      assert [
               %{"id" => _, "post_content" => %{"name" => "Option A"}},
               %{"id" => _, "post_content" => %{"name" => "Option B"}}
             ] = choices
    end

    test "missing poll id returns a GraphQL error instead of a success-shaped empty poll" do
      user = fake_user!()

      {:ok, result} =
        Absinthe.run(@poll_detail, Schema,
          variables: %{"id" => Ecto.UUID.generate()},
          context: Schema.context(%{current_user: user})
        )

      assert result[:errors]
      assert get_in(result, [:data, "poll"]) == nil
    end

    test "weighted poll detail returns weighted choice totals and enriched own votes" do
      author = fake_user!()
      alice = fake_user!()
      bob = fake_user!()
      carol = fake_user!()

      assert {:ok, poll} =
               fake_question_with_choices(
                 %{voting_format: "weighted_multiple", post_content: %{name: "Weighted poll"}},
                 [%{name: "Blockable"}, %{name: "Mixed"}],
                 current_user: author
               )

      [blockable, mixed] = poll.choices

      assert {:ok, _} = Votes.vote(alice, poll, [%{choice_id: blockable.id, weight: "∞"}])
      assert {:ok, _} = Votes.vote(bob, poll, [%{choice_id: mixed.id, weight: 2}])
      assert {:ok, _} = Votes.vote(carol, poll, [%{choice_id: mixed.id, weight: -1}])

      {:ok, result} =
        Absinthe.run(@weighted_poll_detail, Schema,
          variables: %{"id" => poll.id},
          context: Schema.context(%{current_user: alice})
        )

      refute result[:errors]

      choices_by_name =
        result
        |> get_in([:data, "poll", "choices"])
        |> Map.new(&{get_in(&1, ["post_content", "name"]), &1})

      assert get_in(choices_by_name, ["Blockable", "votes_result_total"]) == 0
      assert get_in(choices_by_name, ["Blockable", "votes_result_average"]) == 0
      assert get_in(choices_by_name, ["Mixed", "votes_result_total"]) == 1
      assert get_in(choices_by_name, ["Mixed", "votes_result_average"]) == 1

      assert [
               %{
                 "id" => own_choice_id,
                 "votes_result_total" => 0,
                 "votes_result_average" => 0
               }
             ] = get_in(result, [:data, "poll", "own_votes"])

      assert own_choice_id == blockable.id
    end
  end
end
