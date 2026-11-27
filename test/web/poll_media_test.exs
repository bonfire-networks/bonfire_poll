defmodule Bonfire.Poll.Web.PollMediaTest do
  @moduledoc """
  A poll carries the files uploaded in its composer, as a post does: attached, and placed in its text when the text has their `upload:<ref>` (see `Bonfire.Files.InlineMedia`).

  The composer lives in the sticky `PersistentLive` child LV, so interactions go through `find_live_child(view, "persistent")` rather than PhoenixTest.
  """
  use Bonfire.Poll.ConnCase, async: false
  use Bonfire.Common.Utils
  import Phoenix.LiveViewTest
  import Ecto.Query

  @moduletag :ui

  @poll_form "#smart_input_poll_content form"

  setup do
    account = fake_account!()
    me = fake_user!(account)
    image = Path.expand("../../../bonfire_ui_social/test/fixtures/icon.png", __DIR__)
    {:ok, conn: conn(user: me, account: account), me: me, image: image}
  end

  defp open_poll_composer(conn) do
    {:ok, view, _html} = live(conn, "/feed/local")
    persistent = find_live_child(view, "persistent")
    assert persistent, "sticky PersistentLive child not found"

    persistent
    |> element("#composer_type_menu_panel button[phx-click*='CreatePollLive']")
    |> render_click()

    assert render(persistent) =~ "smart_input_poll_content", "control: the composer writes a poll"
    persistent
  end

  test "the poll composer has an upload button", %{conn: conn} do
    persistent = open_poll_composer(conn)

    assert has_element?(persistent, "input[name=files][type=file]")

    # publishing uploads the files first, to the component the form targets: the composer's, which allows them, not the poll's (LiveView: "no uploads have been allowed on component")
    doc = persistent |> render() |> LazyHTML.from_fragment()
    form = LazyHTML.query(doc, @poll_form)
    [form_target] = LazyHTML.attribute(form, "phx-target")
    [submit] = LazyHTML.attribute(form, "phx-submit")

    [poll_cid] =
      doc
      |> LazyHTML.query("#smart_input_poll_content")
      |> LazyHTML.attribute("data-phx-component")

    refute form_target == poll_cid

    # a `phx-submit` pushing to a target of its own overrides the form's (as Surface's `submit=` does), and the browser uploads there
    assert submit == "Bonfire.Poll:create_poll"
  end

  # a poll's question is a plain text input (since May 2026), not the text editor: it takes markdown as typed, so "Insert in text" places a file there as `![](upload:<ref>)` text (Q29)
  test "the poll's question takes an upload placed with Insert in text", %{
    conn: conn,
    image: image
  } do
    persistent = open_poll_composer(conn)

    assert has_element?(persistent, "#{@poll_form} input[name=files][type=file]")
    assert has_element?(persistent, "#{@poll_form} input#poll_question[data-insert-at-cursor]")

    persistent
    |> file_input(@poll_form, :files, [
      %{name: "icon.png", content: File.read!(image), type: "image/png"}
    ])
    |> render_upload("icon.png")

    [button] =
      render(persistent)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role=insert_in_text]")
      |> LazyHTML.attribute("phx-click")

    # on the button itself, for the field last written in (see `milkdown.hooks.js`)
    assert button =~ "bonfire:insert_at_cursor"
    refute button =~ ~s("to":)
  end

  # an image placed in an option is attached to that option's choice, which shows it, not to the question, whose attachment list would show it again
  test "an image placed in an option is attached to that option, at its stored URL", %{
    conn: conn,
    me: me,
    image: image
  } do
    persistent = open_poll_composer(conn)
    assert has_element?(persistent, "#{@poll_form} input#poll_option_0[data-insert-at-cursor]")

    persistent
    |> file_input(@poll_form, :files, [
      %{name: "icon.png", content: File.read!(image), type: "image/png"}
    ])
    |> render_upload("icon.png")

    [_, ref] = Regex.run(~r/upload_metadata\[([^\]]+)\]/, render(persistent))

    persistent
    |> element(@poll_form)
    |> render_submit(%{
      "post" => %{"post_content" => %{"html_body" => "Which logo?"}},
      "choices" => %{"0" => %{"name" => "![](upload:#{ref})"}, "1" => %{"name" => "Neither"}},
      "poll_preset" => "quick",
      "poll_duration_hours" => "24"
    })

    [media] =
      Bonfire.Common.Repo.all(from(m in Bonfire.Files.Media, where: m.creator_id == ^id(me)))

    [%{id: attached_to}] =
      Bonfire.Common.Repo.all(from(f in Bonfire.Files, where: f.media_id == ^id(media)))

    choice =
      Bonfire.Common.Needles.get!(attached_to, skip_boundary_check: true)
      |> Bonfire.Common.Repo.maybe_preload(:post_content)

    assert %Bonfire.Poll.Choice{} = choice,
           "the image is attached to the option, not the question"

    name = e(choice, :post_content, :name, nil) || e(choice, :post_content, :html_body, nil)
    refute name =~ "upload:"
    assert Bonfire.Files.InlineMedia.inline_ids(name, [media]) == [id(media)]

    # shown in its option, as the question shows its own (`MediaLive`: lightbox, and blurred when sensitive)
    poll_id =
      Bonfire.Common.Repo.one(
        from(q in Bonfire.Poll.Question, select: q.id, order_by: [desc: q.id], limit: 1)
      )

    {:ok, view, _html} = live(conn, "/discussion/#{poll_id}")
    doc = view |> render() |> LazyHTML.from_document()

    option = doc |> LazyHTML.query("[data-id=activity_choice]") |> LazyHTML.to_html()
    assert option =~ ~s(data-id="article_media")
    assert option =~ Path.basename(media.path)

    question = doc |> LazyHTML.query(".object_body") |> LazyHTML.to_html()
    refute question =~ Path.basename(media.path)
  end

  # an option is split as a post's body is: a link in its sentence isn't placed there, so its card still shows, under the option
  test "a link in the middle of an option's sentence keeps its card", %{conn: conn, me: me} do
    url = "https://example.com/a-talk-#{System.unique_integer([:positive])}"

    {:ok, link} =
      Bonfire.Files.save_url_as_media(me, url, %{
        media_type: "link",
        metadata: %{"label" => "A Talk Worth Seeing"}
      })

    {:ok, question} =
      Bonfire.Poll.Fake.fake_question_with_choices(
        %{post_content: %{name: "Which one?"}},
        [
          %{name: "Watch #{url} before voting", html_body: "", uploaded_media: [link]},
          %{name: "Neither", html_body: ""}
        ],
        current_user: me
      )

    assert [_] = Bonfire.Common.Repo.all(from(f in Bonfire.Files, where: f.media_id == ^id(link))),
           "control: the link is attached to its option"

    {:ok, view, _html} = live(conn, "/discussion/#{id(question)}")

    option =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-id=activity_choice]")
      |> LazyHTML.to_html()

    assert option =~ "before voting"
    assert option =~ "A Talk Worth Seeing"
  end

  test "a poll published with an image it doesn't place has it attached, in its attachment list",
       %{
         conn: conn,
         me: me,
         image: image
       } do
    persistent = open_poll_composer(conn)

    persistent
    |> file_input(@poll_form, :files, [
      %{name: "icon.png", content: File.read!(image), type: "image/png"}
    ])
    |> render_upload("icon.png")

    persistent
    |> element(@poll_form)
    |> render_submit(%{
      "post" => %{"post_content" => %{"html_body" => "Which one?"}},
      "choices" => %{"0" => %{"name" => "Yes"}, "1" => %{"name" => "No"}},
      "poll_preset" => "quick",
      "poll_duration_hours" => "24"
    })

    [media] =
      Bonfire.Common.Repo.all(from(m in Bonfire.Files.Media, where: m.creator_id == ^id(me)))

    [%{id: poll_id}] =
      Bonfire.Common.Repo.all(from(f in Bonfire.Files, where: f.media_id == ^id(media)))

    assert %Bonfire.Poll.Question{} =
             Bonfire.Common.Needles.get!(poll_id, skip_boundary_check: true),
           "the image is attached to the poll, not to an option"

    # shown once, in the attachment list: not in the question's text, nor in an option
    {:ok, view, _html} = live(conn, "/discussion/#{poll_id}")
    doc = view |> render() |> LazyHTML.from_document()
    file = Path.basename(media.path)

    assert doc |> LazyHTML.to_html() |> String.split(file) |> length() > 1
    refute doc |> LazyHTML.query(".object_body") |> LazyHTML.to_html() =~ file
    refute doc |> LazyHTML.query("[data-id=activity_choice]") |> LazyHTML.to_html() =~ file
  end

  test "a poll published with an image placed in its text has it attached, at its stored URL", %{
    conn: conn,
    me: me,
    image: image
  } do
    persistent = open_poll_composer(conn)

    persistent
    |> file_input(@poll_form, :files, [
      %{name: "icon.png", content: File.read!(image), type: "image/png"}
    ])
    |> render_upload("icon.png")

    [_, ref] = Regex.run(~r/upload_metadata\[([^\]]+)\]/, render(persistent))

    persistent
    |> element(@poll_form)
    |> render_submit(%{
      "post" => %{"post_content" => %{"html_body" => "Which one?\n\n![](upload:#{ref})"}},
      "choices" => %{"0" => %{"name" => "Yes"}, "1" => %{"name" => "No"}},
      "poll_preset" => "quick",
      "poll_duration_hours" => "24"
    })

    [media] =
      Bonfire.Common.Repo.all(from(m in Bonfire.Files.Media, where: m.creator_id == ^id(me)))

    [%{id: poll_id}] =
      Bonfire.Common.Repo.all(from(f in Bonfire.Files, where: f.media_id == ^id(media)))

    body =
      Bonfire.Common.Needles.get!(poll_id, skip_boundary_check: true)
      |> Bonfire.Common.Repo.maybe_preload(:post_content)
      |> e(:post_content, :html_body, nil)

    refute body =~ "upload:"
    assert Bonfire.Files.InlineMedia.inline_ids(body, [media]) == [id(media)]

    # shown where it sits in the question, as a post shows its inline media (`MediaLive`: lightbox, and blurred when sensitive), once
    {:ok, view, _html} = live(conn, "/discussion/#{poll_id}")
    html = render(view)

    question =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".object_body")
      |> LazyHTML.to_html()

    assert question =~ ~s(data-id="article_media")
    assert question =~ Path.basename(media.path)
  end

  describe "a file that fails to upload" do
    @gps_fixtures Path.expand("../../../bonfire_files/test/fixtures/gps", __DIR__)

    defp submit_poll_with(persistent, fixture, type) do
      name = Path.basename(fixture)

      persistent
      |> file_input(@poll_form, :files, [
        %{name: name, content: File.read!(Path.join(@gps_fixtures, fixture)), type: type}
      ])
      |> render_upload(name)

      persistent
      |> element(@poll_form)
      |> render_submit(%{
        "post" => %{"post_content" => %{"html_body" => "Which one?"}},
        "choices" => %{"0" => %{"name" => "Yes"}, "1" => %{"name" => "No"}},
        "poll_preset" => "quick",
        "poll_duration_hours" => "24"
      })
    end

    defp polls_count, do: Bonfire.Common.Repo.aggregate(Bonfire.Poll.Question, :count)

    test "a clean image is published with the poll (control)", %{conn: conn} do
      persistent = open_poll_composer(conn)
      before = polls_count()

      submit_poll_with(persistent, "clean.jpg", "image/jpeg")

      assert polls_count() == before + 1
    end

    test "a file that carries a location is refused: the error names it, no poll is created, the text and the file stay",
         %{conn: conn} do
      persistent = open_poll_composer(conn)
      before = polls_count()

      submit_poll_with(persistent, "gps.pdf", "application/pdf")

      # the flash is shown by the persistent LiveView the composer lives in
      flash =
        persistent
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("[data-id=flash]")
        |> Floki.text()

      assert flash =~ "gps.pdf"
      assert flash =~ "location data"
      assert polls_count() == before
      refute_push_event(persistent, "smart_input:reset", %{})
      assert render(persistent) =~ "gps.pdf"
    end
  end
end
