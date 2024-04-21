if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Poll.API.GraphQL do
    use Absinthe.Schema.Notation
    use Absinthe.Relay.Schema.Notation, :modern

    import Bonfire.Poll.Integration
    import Untangle

    alias Absinthe.Resolution.Helpers
    alias Bonfire.API.GraphQL
    alias Bonfire.API.GraphQL.Pagination
    alias Bonfire.Common.Utils
    alias Bonfire.Common.Types
    alias Bonfire.Poll.Questions

    # import_types(Absinthe.Type.Custom)

    object :choice do
      field(:id, :id)
      field(:post_content, :post_content)
    end

    object :poll do
      field(:id, :id)
      field(:post_content, :post_content)
      field(:choices, list_of(:choice))
      field(:activity, :activity)
    end

    connection(node_type: :poll)

    input_object :poll_filters do
      field(:id, :id)
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

      # field :vote, :activity do
      #   arg(:username, non_null(:string))
      #   arg(:id, non_null(:string))

      #   resolve(&vote/2)
      # end
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

    # defp prepare_list(%{edges: items_page}) when is_list(items_page) do
    #   items_page
    # end

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

    # defp vote(%{id: to_follow}, info) do
    #   current_user = GraphQL.current_user(info)

    #   if current_user do
    #     with {:ok, f} <- Votes.vote(current_user, question, votes),
    #          do: {:ok, Utils.e(f, :activity, nil)}
    #   else
    #     {:error, "Not authenticated"}  
    #   end
    # end
  end
else
  IO.warn("Skip GraphQL API")
end
