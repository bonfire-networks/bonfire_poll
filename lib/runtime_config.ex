defmodule Bonfire.Poll.RuntimeConfig do
  use Bonfire.Common.Localise

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  # Required so `EctoActs.Begin/Work/Commit` in the epic resolve to
  # `Bonfire.Ecto.Acts.*` rather than crashing on a missing literal module.
  alias Bonfire.Ecto.Acts, as: EctoActs

  @question_act_opts [on: :question, attrs: :question_attrs]

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

    # Question-creation epic. Owned here so the extension is self-contained.
    config :bonfire_poll, Bonfire.Poll.Questions,
      epics: [
        create: [
          # Translate composer preset+tuning into Question attrs.
          {Bonfire.Poll.Acts.PresetAttrs, @question_act_opts},
          {Bonfire.Poll.Question.Create, @question_act_opts},
          {Bonfire.Social.Acts.PostContents, @question_act_opts},
          {Bonfire.Me.Acts.Caretaker, @question_act_opts},
          {Bonfire.Me.Acts.Creator, @question_act_opts},
          {Bonfire.Files.Acts.URLPreviews, @question_act_opts},
          {Bonfire.Files.Acts.AttachMedia, @question_act_opts},
          {Bonfire.Tag.Acts.Tag, @question_act_opts},
          {Bonfire.Boundaries.Acts.SetBoundaries, @question_act_opts},
          # Activity casts :feed_publishes via FeedActivities.cast, so a
          # separate Acts.Feeds step would be redundant.
          {Bonfire.Social.Acts.Activity, @question_act_opts},

          # Transaction.
          EctoActs.Begin,
          EctoActs.Work,
          EctoActs.Commit,
          {Bonfire.Poll.Acts.Choices.Create, @question_act_opts},
          {Bonfire.Search.Acts.Queue, @question_act_opts},

          # Oban prefers these out of the transaction.
          {Bonfire.Social.Acts.Federate, @question_act_opts},
          {Bonfire.Tags.Acts.AutoBoost, @question_act_opts}
        ]
      ]
  end
end
