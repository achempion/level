defmodule Level.Nudges do
  @moduledoc """
  The Nudges context.
  """

  import Ecto.Query
  import Level.Gettext

  alias Ecto.Changeset
  alias Level.Digests
  alias Level.Posts
  alias Level.Repo
  alias Level.Schemas.DueNudge
  alias Level.Schemas.Nudge
  alias Level.Schemas.SpaceUser

  @doc """
  Fetches nudges that are due to send.
  """
  @spec due_query(DateTime.t()) :: Ecto.Query.t()
  def due_query(now) do
    inner_query =
      from n in "nudges",
        inner_join: su in "space_users",
        on: su.id == n.space_user_id,
        inner_join: u in "users",
        on: u.id == su.user_id,
        select: %DueNudge{
          id: fragment("?::text", n.id),
          space_id: n.space_id,
          space_user_id: n.space_user_id,
          minute: n.minute,
          time_zone: u.time_zone,
          digest_key:
            fragment(
              "concat('nudge:', ?, ':', to_char(timezone(?, ?), 'yyyy-mm-dd'))",
              n.id,
              u.time_zone,
              ^now
            ),
          current_minute:
            fragment(
              "(date_part('hour', timezone(?, ?))::integer * 60) + date_part('minute', timezone(?, ?))::integer",
              u.time_zone,
              ^now,
              u.time_zone,
              ^now
            )
        }

    from n in subquery(inner_query),
      left_join: d in "digests",
      on: d.key == n.digest_key,
      where: n.current_minute >= n.minute,
      where: n.current_minute < fragment("LEAST(? + 30, 1440)", n.minute),
      where: is_nil(d.id)
  end

  @doc """
  Creates a nudge.
  """
  @spec create_nudge(SpaceUser.t(), map()) :: {:ok, Nudge.t()} | {:error, Changeset.t()}
  def create_nudge(%SpaceUser{} = space_user, params) do
    params_with_relations =
      Map.merge(params, %{
        space_id: space_user.space_id,
        space_user_id: space_user.id
      })

    %Nudge{}
    |> Nudge.create_changeset(params_with_relations)
    |> Repo.insert()
  end

  @doc """
  Gets nudges for a user.
  """
  @spec list_nudges(SpaceUser.t()) :: [Nudge.t()]
  def list_nudges(%SpaceUser{} = space_user) do
    space_user
    |> Ecto.assoc(:nudges)
    |> Repo.all()
  end

  @doc """
  Fetches a nudge by id.
  """
  @spec get_nudge(SpaceUser.t(), String.t()) :: {:ok, Nudge.t()} | {:error, String.t()}
  def get_nudge(%SpaceUser{} = space_user, id) do
    space_user
    |> Ecto.assoc(:nudges)
    |> where([n], n.id == ^id)
    |> Repo.one()
    |> after_fetch()
  end

  defp after_fetch(%Nudge{} = nudge) do
    {:ok, nudge}
  end

  defp after_fetch(_) do
    {:error, dgettext("errors", "Nudge not found")}
  end

  @doc """
  Deletes a nudge.
  """
  @spec delete_nudge(Nudge.t()) :: {:ok, Nudge.t()} | {:error, Changeset.t()}
  def delete_nudge(%Nudge{} = nudge) do
    Repo.delete(nudge)
  end

  @doc """
  Builds digest options based on "due nudge" data.
  """
  @spec digest_options(DueNudge.t(), DateTime.t()) :: Digests.Options.t()
  def digest_options(due_nudge, now) do
    %Digests.Options{
      title: "Recent Activity",
      key: due_nudge.digest_key,
      start_at: now,
      end_at: now,
      time_zone: due_nudge.time_zone,
      sections: []
    }
  end

  @doc """
  Filter a list of due nudge records to only include ones that should send.
  """
  @spec filter_sendable([DueNudge.t()], DateTime.t()) :: [DueNudge.t()]
  def filter_sendable(due_nudges, now) do
    due_nudges_with_preloads = Repo.preload(due_nudges, :space_user)

    Enum.filter(due_nudges_with_preloads, fn due_nudge ->
      space_user = due_nudge.space_user

      # Check to see if their is at least one unread post today
      get_first_unread_today(space_user, now) != nil
    end)
  end

  @doc """
  Builds a digest for a due nudge.
  """
  @spec build(DueNudge.t(), DateTime.t()) :: {:ok, Digest.t()} | {:error, String.t()}
  def build(due_nudge, now) do
    due_nudge = Repo.preload(due_nudge, :space_user)
    opts = digest_options(due_nudge, now)
    Digests.build(due_nudge.space_user, opts)
  end

  # Private helpers

  defp get_first_unread_today(space_user, now) do
    space_user
    |> Posts.Query.base_query()
    |> Posts.Query.select_last_activity_at()
    |> Posts.Query.where_unread_in_inbox()
    |> Posts.Query.where_last_active_today(now)
    |> limit(1)
    |> Repo.one()
  end
end
