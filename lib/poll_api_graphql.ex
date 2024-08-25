if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Poll.API.GraphQL do
    use Absinthe.Schema.Notation
    use Absinthe.Relay.Schema.Notation, :modern

    use Bonfire.Common.E
    import Bonfire.Poll
    import Untangle

    alias Absinthe.Resolution.Helpers
    alias Bonfire.API.GraphQL
    alias Bonfire.API.GraphQL.Pagination
    alias Bonfire.Common.Utils
    alias Bonfire.Common.Types
    alias Bonfire.Poll.Questions
    alias Bonfire.Poll.Votes

    # import_types(Absinthe.Type.Custom)

    object :poll do
      field(:id, :id)
      field(:post_content, :post_content)
      field(:choices, list_of(:choice))
      field(:activity, :activity)
    end

    connection(node_type: :poll)

    object :choice do
      field(:id, :id)
      field(:post_content, :post_content)
    end

    object :score do
      field(:weight, :string)
      field(:icon, :string)
      field(:name, :string)
      field(:summary, :string)
    end

    input_object :poll_filters do
      field(:id, :id)
    end

    input_object :vote_input do
      field(:choice_id, :id)
      field(:weight, :string)
    end

    object :poll_queries do
      @desc "Get all polls"
      # field :polls, list_of(:poll) do
      #   resolve(&list_polls/3)
      # end
      connection field :polls, node_type: :poll do
        resolve(&list_polls/3)
      end

      @desc "Get a poll"
      field :poll, :poll do
        arg(:filter, :poll_filters)
        resolve(&get_poll/3)
      end

      @desc "List default possible scores"
      field :default_scores, list_of(:score) do
        resolve(&list_scores/3)
      end
    end

    object :poll_mutations do
      field :create_poll, :poll do
        arg(:post_content, non_null(:post_content_input))

        arg(:choices, list_of(:post_content_input))

        arg(:reply_to, :id)
        arg(:boundary, :string)
        arg(:to_circles, list_of(:id))

        resolve(&create_poll/2)
      end

      field :vote, :activity do
        arg(:poll_id, non_null(:string))
        arg(:votes, list_of(:vote_input))

        resolve(&vote/2)
      end
    end

    # def list_polls(_parent, args, info) do
    #   {:ok,
    #    Questions.list_paginated(Map.to_list(args), GraphQL.current_user(info)) |> prepare_list()}
    # end
    def list_polls(_parent, args, info) do
      {pagination_args, filters} =
        Pagination.pagination_args_filter(args)
        |> debug()

      Questions.list_paginated(filters,
        current_user: GraphQL.current_user(info),
        pagination: pagination_args
      )
      |> Pagination.connection_paginate(pagination_args)
    end

    def list_scores(_, _, _) do
      {:ok,
       Bonfire.Poll.Votes.scores()
       |> Enum.map(fn {i, name, icon, summary} ->
         %{weight: i, name: name, icon: icon, summary: summary}
       end)}
    end

    def get_poll(_parent, %{filter: %{id: id}} = _args, info) do
      Questions.read(id, GraphQL.current_user(info))
    end

    defp create_poll(args, info) do
      current_user = GraphQL.current_user(info)

      if current_user do
        [
          current_user: current_user,
          question_attrs: args
          #  boundary: e(params, "to_boundaries", "mentions")
        ]
        |> debug("opts with attrs")
        |> Questions.create()
      else
        {:error, "Not authenticated"}
      end
    end

    defp vote(%{poll_id: question, votes: votes}, info) do
      current_user = GraphQL.current_user(info)

      if not is_nil(current_user) do
        with {:ok, f} <-
               Votes.vote(
                 current_user,
                 question,
                 votes
                 |> Enum.map(fn
                   %{choice_id: choice_id, weight: weight} ->
                     {choice_id, weight}

                   other ->
                     error(other, "invalid input")
                     raise Bonfire.Fail, :invalid_argument
                 end)
                 |> debug("votes")
               ),
             do: {:ok, e(f, :activity, nil) || f}
      else
        # {:error, "Not authenticated"}  
        raise(Bonfire.Fail.Auth, :needs_login)
      end
    end
  end
else
  IO.warn("Skip GraphQL API")
end
