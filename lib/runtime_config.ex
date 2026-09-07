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

    # When poll results become visible to people other than the poll's owner:
    #   :after_vote (default) — once the viewer has voted, or after the poll closes
    #   :after_close          — only after voting ends
    #   :always               — always visible
    config :bonfire_poll, :results_visibility, :after_vote

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
        # Grouped into parallel stages mirroring the `Bonfire.Posts` `:publish` epic, so the two behave the same way: a nested list runs in parallel, and each group may depend on the outputs of the ones before it. Keeping the same shape is what keeps the two orderings that matter in step — `SetBoundaries` before `Tag`, and `Federate` (which links an incoming AP object) before `AutoBoost` (which relays it).
        create: [
          # Prep: translate composer preset+tuning into Question attrs, then build the changeset.
          {Bonfire.Poll.Acts.PresetAttrs, @question_act_opts},
          {Bonfire.Poll.Question.Create, @question_act_opts},

          # These steps are run in parallel
          [
            # with a sanitised body and tags extracted,
            {Bonfire.Social.Acts.PostContents, @question_act_opts},

            # possibly occurring in a thread — sets thread/reply_to (creating a `Replied` record,
            # with reply_to_id=nil for a non-reply) so polls join threaded discussions like posts.
            {Bonfire.Social.Acts.Threaded, @question_act_opts}
          ],

          # These steps are run in parallel and require the outputs of the previous ones
          [
            # possibly fetch contents of URLs (depends on PostContents),
            {Bonfire.Files.Acts.URLPreviews, @question_act_opts},

            # with appropriate boundaries established (depends on Threaded and PostContents),
            {Bonfire.Boundaries.Acts.SetBoundaries, @question_act_opts}
          ],

          # These steps are run in parallel and require the outputs of the previous ones
          [
            # possibly with uploaded/linked media (optionally depends on URLPreviews),
            {Bonfire.Files.Acts.AttachMedia, @question_act_opts},

            # with extracted tags/mentions fully hooked up (depends on PostContents),
            {Bonfire.Tag.Acts.Tag, @question_act_opts},

            # summarised by an activity — casts :feed_publishes via FeedActivities.cast, so a
            # separate Acts.Feeds step would be redundant.
            {Bonfire.Social.Acts.Activity, @question_act_opts},
            {Bonfire.Me.Acts.Caretaker, @question_act_opts},
            {Bonfire.Me.Acts.Creator, @question_act_opts}
          ],

          # Now we have a short critical section
          EctoActs.Begin,
          EctoActs.Work,
          EctoActs.Commit,
          {Bonfire.Poll.Acts.Choices.Create, @question_act_opts},

          # These steps are run in parallel. Oban prefers them out of the transaction.
          [
            {Bonfire.Search.Acts.Queue, @question_act_opts},
            {Bonfire.Social.Acts.Federate, @question_act_opts}
          ],

          # Once the activity/object exists (including in AP db), we can apply these extra side effects
          {Bonfire.Tags.Acts.AutoBoost, @question_act_opts}
        ]
      ]
  end
end
