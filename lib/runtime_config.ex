defmodule Bonfire.Poll.RuntimeConfig do
  use Bonfire.Common.Localise

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  @doc """
  NOTE: you can override this default config in your app's `runtime.exs`, by placing similarly-named config keys below the `Bonfire.Common.Config.LoadExtensionsConfig.load_configs()` line
  """
  def config do
    import Config

    # config :bonfire_poll,
    #   modularity: :disabled

    config :bonfire, :ui,
      activity_preview: [
        # TODO: vote activity
      ],
      object_preview: [
        {Bonfire.Poll.Question, Bonfire.Poll.Web.Preview.QuestionLive},
        {Bonfire.Poll.Choice, Bonfire.Poll.Web.Preview.ChoiceLive}
      ]
  end
end
