if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Poll.API.GraphQL.CreatePollTest do
    use Bonfire.Poll.DataCase, async: false

    import Bonfire.Me.Fake

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @create_poll """
    mutation($content: PostContentInput!, $choices: [PostContentInput], $durationHours: Int) {
      create_poll(post_content: $content, choices: $choices, duration_hours: $durationHours) {
        id
        voting_open_at
        voting_close_at
        choices {
          id
          post_content {
            name
          }
        }
      }
    }
    """

    test "create_poll returns a stable poll id and usable choices" do
      user = fake_user!()

      {:ok, result} =
        Absinthe.run(@create_poll, Schema,
          variables: %{
            "content" => %{"html_body" => "Choose a release train"},
            "choices" => [%{"name" => "Stable"}, %{"name" => "Beta"}],
            "durationHours" => 48
          },
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors]

      poll = get_in(result, [:data, "create_poll"])
      assert is_binary(poll["id"]) and poll["id"] != ""
      assert poll["voting_open_at"]
      assert poll["voting_close_at"]

      assert [
               %{"id" => choice_a_id, "post_content" => %{"name" => "Stable"}},
               %{"id" => choice_b_id, "post_content" => %{"name" => "Beta"}}
             ] = poll["choices"]

      assert is_binary(choice_a_id) and choice_a_id != ""
      assert is_binary(choice_b_id) and choice_b_id != ""
    end

    test "create_poll rejects missing choices instead of returning a hollow poll" do
      user = fake_user!()

      {:ok, result} =
        Absinthe.run(@create_poll, Schema,
          variables: %{
            "content" => %{"html_body" => "No options"},
            "choices" => []
          },
          context: Schema.context(%{current_user: user})
        )

      assert result[:errors]
      assert get_in(result, [:data, "create_poll"]) == nil
    end

    test "create_poll rejects blank choices instead of creating an empty choices list" do
      user = fake_user!()

      {:ok, result} =
        Absinthe.run(@create_poll, Schema,
          variables: %{
            "content" => %{"html_body" => "Blank options"},
            "choices" => [%{"name" => "  "}]
          },
          context: Schema.context(%{current_user: user})
        )

      assert result[:errors]
      assert get_in(result, [:data, "create_poll"]) == nil
    end
  end
end
