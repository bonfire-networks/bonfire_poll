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

    @poll_results """
    query($id: ID!) {
      poll(filter: {id: $id}) {
        votes_count
        voters_count
        choices {
          post_content {
            name
          }
          votes_result_total
          votes_result_average
        }
      }
    }
    """

    defp poll_results(poll, viewer) do
      {:ok, result} =
        Absinthe.run(@poll_results, Schema,
          variables: %{"id" => poll.id},
          context: Schema.context(%{current_user: viewer})
        )

      refute result[:errors]
      poll_result = get_in(result, [:data, "poll"])

      choices =
        Map.new(poll_result["choices"], fn choice ->
          {get_in(choice, ["post_content", "name"]),
           {choice["votes_result_total"], choice["votes_result_average"]}}
        end)

      {poll_result["votes_count"], poll_result["voters_count"], choices}
    end

    test "multiple poll results count each pick, and voters once" do
      author = fake_user!()
      [v1, v2, v3, v4] = for _ <- 1..4, do: fake_user!()

      assert {:ok, poll} =
               fake_question_with_choices(
                 %{voting_format: "multiple"},
                 [%{name: "A"}, %{name: "B"}, %{name: "C"}],
                 current_user: author
               )

      [a, b, c] = poll.choices

      pick = fn voter, choices ->
        Votes.vote(voter, poll, Enum.map(choices, &%{choice_id: &1.id, weight: 1}))
      end

      assert {:ok, _} = pick.(v1, [a, b])
      assert {:ok, _} = pick.(v2, [a, c])
      assert {:ok, _} = pick.(v3, [a])
      assert {:ok, _} = pick.(v4, [b, c])

      assert {7, 4, %{"A" => {3, nil}, "B" => {2, nil}, "C" => {2, nil}}} =
               poll_results(poll, author)
    end

    test "weighted poll results scale negatives by weighting, floor at 0, and leave Block out of the score" do
      author = fake_user!()
      [p1, p2, p3, p4, p5, p6, p7] = for _ <- 1..7, do: fake_user!()

      assert {:ok, poll} =
               fake_question_with_choices(
                 %{voting_format: "weighted_multiple", weighting: 3},
                 [%{name: "A"}, %{name: "B"}, %{name: "C"}, %{name: "D"}],
                 current_user: author
               )

      [a, b, c, d] = poll.choices

      react = fn voter, reactions ->
        Votes.vote(
          voter,
          poll,
          Enum.map(reactions, fn {choice, weight} -> %{choice_id: choice.id, weight: weight} end)
        )
      end

      assert {:ok, _} = react.(p1, [{a, 2}, {b, 2}])
      assert {:ok, _} = react.(p2, [{a, 2}, {b, 2}])
      assert {:ok, _} = react.(p3, [{a, 2}, {c, 1}])
      assert {:ok, _} = react.(p4, [{a, -1}, {b, 1}])
      assert {:ok, _} = react.(p5, [{b, -1}])
      assert {:ok, _} = react.(p6, [{b, -1}, {d, 0}])
      assert {:ok, _} = react.(p7, [{c, "∞"}])

      # A: 6 - 1×3 = 3 over 4 reactions, average 0.75 rounds to 1.
      # B: 5 - 2×3 = -1, floored to 0 (it would be 3 if weighting were ignored).
      # C: the Block counts neither in the total nor in the average's denominator.
      assert {12, 7,
              %{
                "A" => {3, 1},
                "B" => {0, 0},
                "C" => {1, 1},
                "D" => {0, 0}
              }} = poll_results(poll, author)
    end

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
